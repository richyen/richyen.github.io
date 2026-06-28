---
layout: post
title:  "Are You .ready?"
date:   2026-07-06 00:00:00 -0800
tags: PostgreSQL postgres wal archiving archive_command replication streaming-replication logical-replication replication-slots
comments: true
categories: postgres
---

# A practical guide to what `.ready` and `.done` mean, and why WAL sticks around

## Introduction

It is 9:12 a.m. on a Monday.  Someone on your team opens `pg_wal/archive_status/` during a storage scare and sees a long list of files ending in `.ready`.  They ask the question many of us have asked at least once: "Is replication broken?" Streaming replicas still look mostly fine, but `.ready` files keep piling up, disk usage keeps climbing, and nobody is fully sure what `.ready` and `.done` are actually telling you.

What is `.ready` and what (if any) action do I need to take?  Let's talk about that today.

---

## Hint: It's About WAL Delivery

Think of WAL delivery as three independent steps:

1. Generate WAL
2. Transport WAL
3. Replay or consume WAL

`archive_command` is one way to do **transport**.  Streaming replication is another.  Note, logical replication also has a transport channel, but what it transports is decoded logical change data rather than raw WAL segment files.

---

## What `archive_command` Actually Does

When `archive_mode=on`, Postgres tries to copy each completed WAL segment to long-term storage by running `archive_command`.

Typical example:

```conf
archive_mode = on
archive_command = 'rsync -a %p backup@walbox:/archives/%f'
```

- `%p` is the local path to the WAL segment in `pg_wal`
- `%f` is just the filename

Postgres runs this command from the archiver process.  If the command exits with status `0`, Postgres treats it as success.  Any non-zero exit code means failure, and it retries later.

> **Info:** Archiving usually happens when a WAL segment is complete (typically 16 MB), not every transaction.  So pure archive shipping can have more lag unless segment switches happen frequently.

---

## What `.ready` and `.done` Are For

Inside `pg_wal/archive_status/`, Postgres tracks each WAL segment's archiving state with tiny marker files.

For a segment named:

`000000010000000A000000FE`

you may see:

- `000000010000000A000000FE.ready`
- `000000010000000A000000FE.done`

### `.ready`

`.ready` means: *"this WAL segment should be archived (or retried)."*

Postgres creates `.ready` when the segment becomes eligible for archiving.  If `archive_command` fails, `.ready` remains and the archiver keeps retrying.  Note, you'll see information about failures in the Postgres text logs, so check there if you see many `.ready` files and not a lot of `.done` files.

### `.done`

`.done` means: *"archiving for this WAL segment succeeded."*

After a successful `archive_command`, Postgres marks completion with `.done` and no longer retries that file.

In short:

- `.ready` = pending/retry queue item
- `.done` = WAL archive was successful

These are local bookkeeping files. They are not WAL themselves.

### If `.done` Exists, When Is It Deleted?

Great question, because `.done` does **not** mean "delete immediately."

In practice, The WAL segment in `pg_wal` can only be recycled/removed after a checkpoint and only when Postgres no longer needs it. This includes retention constraints like replication slots, `wal_keep_size`, or standby/recovery requirements. If a segment is still needed for any of those reasons, it stays in `pg_wal` even if archiving already succeeded.

The `.done` file is just archive-status metadata. It is cleaned up later as part of normal WAL housekeeping, and it can exist for a while even after archival success.

### What If `.done` Files Pile Up and Do Not Disappear?

If `.done` files accumulate, first separate "cosmetic" from "capacity risk":

1. Check whether `pg_wal` disk usage is actually growing.
2. If disk usage is stable, this can be harmless housekeeping lag.
3. If disk usage is growing, treat it as WAL retention pressure.

Then run the diagnostic queries in the **Beginner-Friendly Checks** section below.

Finally, remember that WAL recycle/removal is checkpoint-driven.  If checkpoints are infrequent and WAL is still needed, `.done` files can legitimately linger.

---

## How This Relates to Streaming Replication

Streaming replication and WAL archiving can both exist at the same time, and they are distinct WAL delivery mechanisms with different telemetry and failure modes.

With streaming replication, WAL is pushed over a live replication connection (`walsender` -> `walreceiver`) and can be delivered before a segment is fully closed.  It shows up in `pg_stat_replication` and can use physical replication slots.

On the other hand, archive shipping copies WAL files out via `archive_command` in a segment-oriented way (usually after file completion), does not require a direct live receiver session, and does **not** appear as a row in `pg_stat_replication`.

Important: `.ready/.done` are about the archiver path, not the streaming path.  A standby can be fully healthy on streaming while archiving is broken, or vice versa.

### What About `pg_receivewal`?

`pg_receivewal` is a useful middle ground: it uses the streaming replication protocol to receive WAL continuously, but writes WAL segment files to disk like an archive pipeline.

In other words, transport is streaming, while storage is file-based.

That means:

- It can reduce archive lag compared to waiting for `archive_command` segment completion behavior.
- It can use a replication slot (recommended) so WAL is not lost if the receiver is briefly down.
- It shows up as a replication sender/receiver relationship, unlike local `.ready/.done` bookkeeping.

Also important: `pg_receivewal` does not replace `.ready/.done` on the primary by itself.  Those files are specifically tied to `archive_command`/archiver bookkeeping on that server.

---

## Replication Slots: Where People Get Confused

Replication slots and `archive_command` solve different problems.

- **Physical replication slot:** A physical slot protects WAL needed by a streaming standby.  Postgres will retain WAL until that standby has consumed it.
- **Logical replication slot:** A logical slot protects WAL needed for logical decoding/subscribers.  If the subscriber lags, WAL is retained.
- **Archiving:** Archiving is about making durable WAL copies somewhere else.  It does not tell Postgres what a standby has consumed.

So WAL retention pressure can come from multiple places at once:

- archiving not succeeding (files stay pending)
- lagging physical slot
- lagging logical slot
- infrequent checkpoints (recycle/removal cadence is delayed)

When disk fills in `pg_wal`, it is often one of these, or a combination.  Even after successful archiving, WAL segments are only eligible for recycle/removal after checkpoint processing.

---

## Beginner-Friendly Checks

A few quick checks I like:

```sql
-- Archiver health
SELECT archived_count, failed_count, last_archived_wal, last_failed_wal
FROM pg_stat_archiver;

-- Streaming health
SELECT application_name, state, sync_state, write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- Slot retention pressure
SELECT slot_name, slot_type, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;

-- Quantify physical slot lag in bytes from current WAL position
SELECT slot_name,
	   active,
	   pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS bytes_behind
FROM pg_replication_slots
WHERE slot_type = 'physical';
```

What to look for:

- **`pg_stat_archiver`:** `failed_count` should not climb continuously.  `archived_count` and `last_archived_wal` should move forward during write activity.  If `last_failed_wal` keeps changing but `last_archived_wal` does not, archiving is unhealthy.
- **`pg_stat_replication`:** `state` should usually be `streaming` (or `sync_state` aligned with your design).  Persistent high `write_lag`/`flush_lag`/`replay_lag`, or missing expected standbys, points to transport/replay trouble.
- **`pg_replication_slots`:** watch for inactive slots with old `restart_lsn` (physical) or stale `confirmed_flush_lsn` (logical).  Large `bytes_behind` is a strong signal that a slot is pinning WAL and growing `pg_wal`.

And on disk:

```bash
ls -1 $PGDATA/pg_wal/archive_status | tail
```

If `.ready` files keep piling up, your archive path is unhealthy.
If `.done` files pile up *and* `pg_wal` keeps growing, check slot lag and checkpoint cadence.
If slot lag keeps growing, your consumer is unhealthy.

---

## Final Thoughts

`.ready` and `.done` files are not mysterious once you view them as a local queue and completion marker for `archive_command`.

They are adjacent to replication, but not identical to streaming replication or logical replication.

Getting comfortable with these distinctions makes debugging much faster, especially when someone says, "replication is broken," and you need to answer: *which replication path?*
