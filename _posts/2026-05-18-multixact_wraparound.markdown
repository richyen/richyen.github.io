---
layout: post
title:  "XID Wraparound's Equally-Evil Twin"
date:   2026-05-18 00:00:00 -0600
tags: PostgreSQL postgres vacuum multixact wraparound maintenance autovacuum
comments: true
categories: postgres
---

## Introduction

If you've been running PostgreSQL for any length of time, you've probably heard about transaction ID (XID) wraparound.  It's one of the most well-known maintenance concerns in Postgres, and there's no shortage of blog posts, conference talks, and war stories about it.  But there's a quieter, less-discussed cousin that can cause the exact same kind of outage: **MultiXact ID wraparound**.

I've seen this surprise more than a few experienced DBAs.  They've got their autovacuum tuned, they're monitoring `age(datfrozenxid)`, and they're feeling good -- and then out of nowhere, Postgres starts refusing certain writes because it's approaching MultiXact ID wraparound.

The fix is the same as regular XID wraparound -- a simple vacuum.  But the reason is different, and understanding it can help you keep your monitoring complete.

## What's a MultiXact ID?

In Postgres, every row has a system column called `xmax`.  In the simplest case, `xmax` holds the transaction ID of the transaction that deleted or updated the row.  But what happens when *multiple* transactions hold locks on the same row at the same time?

Consider `SELECT ... FOR SHARE`.  Multiple transactions can hold a shared lock on the same row concurrently.  Postgres needs to record *all* of those transactions somewhere, but `xmax` is only wide enough to store a single transaction ID.  The solution is the **MultiXact** mechanism.

A MultiXact ID is essentially a pointer into a separate structure (stored as a file in the `pg_multixact/` dir) that maps to a *list* of transaction IDs and their lock modes.  When multiple transactions need to lock a row, Postgres:

1. Allocates a new MultiXact ID
2. Records the set of transaction IDs (and their lock types) in the MultiXact member data
3. Stores the MultiXact ID in the row's `xmax` field, with a flag (specifically, the `HEAP_XMAX_IS_MULTI` infomask bit in the tuple header) indicating it's a multi-xact reference rather than a plain XID

This lets the `xmax` field stay a fixed 32-bit value while still representing an arbitrary number of concurrent row-level lockers.

## When Are MultiXact IDs Created?

MultiXact IDs come into play in several scenarios:

- **`SELECT ... FOR SHARE`** -- The classic case.  Multiple transactions can hold shared row locks simultaneously.
- **`SELECT ... FOR KEY SHARE`** -- Used implicitly by foreign key checks.  If you have a parent table with foreign key references, every insert or update on the child table takes a `FOR KEY SHARE` lock on the referenced parent row.  On a busy system with many concurrent inserts referencing the same parent rows, this generates MultiXact IDs rapidly.
- **Combination locks** -- If one transaction holds a `FOR KEY SHARE` lock and another holds a `FOR NO KEY UPDATE` lock on the same row, the two locks don't conflict, and the resulting multi-lock is stored as a MultiXact.

The foreign key scenario is particularly noteworthy because it's *invisible* to most application developers.  You won't see any queries explicitly calling out `FOR SHARE` in application code, but Postgres is silently creating MultiXact IDs behind the scenes to manage the implicit locks.

## MultiXact IDs Need Freezing Too!

Just like transaction IDs, MultiXact IDs are 32-bit counters.  And just like XIDs, they wrap around.  Postgres can only "see" about 2 billion MultiXact IDs into the past.  If a row still references a MultiXact ID that's about to fall off the visible horizon, Postgres has a problem: it can no longer determine whether the locks represented by that MultiXact are still relevant.

To prevent this, Postgres needs to **freeze** MultiXact IDs, just as it freezes regular XIDs.  Freezing a MultiXact means replacing the MultiXact reference in the row's `xmax` with either the zero value, a single transaction ID, or a newer multixact ID, depending on whether the lock information is still meaningful.

The relevant settings mirror those for XID freezing:

| XID Setting | MultiXact Equivalent |
|---|---|
| `vacuum_freeze_min_age` | `vacuum_multixact_freeze_min_age` |
| `vacuum_freeze_table_age` | `vacuum_multixact_freeze_table_age` |
| `autovacuum_freeze_max_age` | `autovacuum_multixact_freeze_max_age` |

When the MultiXact age of a table exceeds `autovacuum_multixact_freeze_max_age`, autovacuum will trigger an aggressive (whole-table) vacuum specifically to freeze old MultiXact IDs -- even if the table has no dead tuples and wouldn't otherwise qualify for autovacuum.

## Don't Let MultiXact Fly Under the Radar

The query is straightforward:

```sql
SELECT datname,
       age(datfrozenxid) AS xid_age,
       mxid_age(datminmxid) AS mxid_age
  FROM pg_database
 ORDER BY mxid_age DESC;
```

For per-table granularity:

```sql
SELECT c.oid::regclass AS table_name,
       age(c.relfrozenxid) AS xid_age,
       mxid_age(c.relminmxid) AS mxid_age
  FROM pg_class c
 WHERE c.relkind IN ('r', 't', 'm')
 ORDER BY mxid_age DESC
 LIMIT 20;
```

Keep an eye on any table where `mxid_age` is approaching `autovacuum_multixact_freeze_max_age` (default: 400 million).  If it gets close, autovacuum *should* kick in, but on large tables or systems with constrained autovacuum workers, it may not complete in time.

## Practical Recommendations

1. **Add MultiXact monitoring alongside XID monitoring.**  If your alerting triggers at, say, 500 million XID age, add a similar alert for MultiXact age.

2. **Watch your foreign key parent tables.**  If you have a `users` or `accounts` table that's referenced by every other table in the schema, it's likely accumulating MultiXact IDs faster than you'd expect.

3. **Consider `autovacuum_multixact_freeze_max_age` tuning.**  The default of 400 million is higher than the XID `autovacuum_freeze_max_age` default of 200 million.  But in workloads with heavy foreign key activity, you may want to lower it -- or configure per-table autovacuum settings on hot parent tables.

4. **Don't ignore "unnecessary" vacuums.**  If you see autovacuum running on a table that has zero dead tuples, don't assume it's wasting resources.  It may be performing MultiXact freezing work that's critical for preventing wraparound.

## Conclusion

MultiXact ID wraparound is the kind of problem that bites you precisely because you didn't know to look for it.  The mechanism exists for a good reason -- efficiently tracking shared row locks is fundamental to Postgres's concurrency model.  But the maintenance burden it creates is real, and it demands the same vigilance as XID wraparound.

If you take one thing away from this post: go check `mxid_age(datminmxid)` on your databases today.  If you've never looked at it before, now's a good time to start.
