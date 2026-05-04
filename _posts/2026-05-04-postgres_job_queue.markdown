---
layout: post
title:  "Potential Consequences of Using Postgres as a Job Queue"
date:   2026-05-04 00:00:00 -0600
tags: PostgreSQL postgres performance scaling job-queue multixact lwlock advisory-locks redis kafka pgq
comments: true
categories: postgres
---

*This post was originally published on the [Microsoft Tech Community Blog](https://techcommunity.microsoft.com/blog/adforpostgresql/potential-consequences-of-using-postgres-as-a-job-queue/4514332).*

## Introduction

At small scale, using Postgres as a job queue is totally fine, and I'd even say it's the right call.  Fewer moving parts, one less system to manage, ACID guarantees on your jobs.  What's not to love?

The problem is that "small scale" has a ceiling, and the ceiling is lower than most people expect.  When you've got thousands of concurrent workers hammering a jobs table with `SELECT ... FOR UPDATE SKIP LOCKED`, things start to behave in ways that aren't obvious from the application layer.  CPU usage creeps up.  Also vacuum sometimes can't keep up.  Finally, in the wait event stats, you start seeing ominous entries like `LWLock:MultiXactSLRU` stacking up across many backends.

This pattern has tripped up teams more than a few times, and it usually plays out the same way: everything works fine in dev and staging, then goes off a cliff in production once the concurrency gets real.  So let's dig into why this happens, and what the alternatives look like.

---

## The Typical Pattern

When using Postgres as a job queue, the standard approach looks something like this:

```sql
CREATE TABLE job_queue (
    id         bigserial PRIMARY KEY,
    status     text NOT NULL DEFAULT 'pending',
    payload    jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    locked_by  text,
    locked_at  timestamptz
);

CREATE INDEX idx_job_queue_status ON job_queue (status) WHERE status = 'pending';
```

Workers grab jobs with:

```sql
UPDATE job_queue
   SET status = 'processing',
       locked_by = 'worker-42',
       locked_at = now()
 WHERE id = (
     SELECT id FROM job_queue
      WHERE status = 'pending'
      ORDER BY created_at
      LIMIT 1
        FOR UPDATE SKIP LOCKED
 )
 RETURNING *;
```

And then mark them done:

```sql
UPDATE job_queue SET status = 'completed' WHERE id = $1;
```

Some users may `DELETE` the row entirely.  Either way, the lifecycle is: insert, lock-and-update, update-or-delete.  Repeated thousands of times per second.

At low concurrency, this works very smoothly.  `SKIP LOCKED` means workers don't block each other waiting for the same row.  Postgres handles the locking, visibility, and ordering.  It's elegant.

So where does it break?

---

## The MultiXact SLRU Problem

When multiple transactions hold locks on the same row, Postgres stores the set of lockers as a MultiXact ID -- a pointer into a side structure under `pg_multixact/`.

With `SELECT ... FOR UPDATE SKIP LOCKED`, users might think MultiXacts aren't involved -- after all, `SKIP LOCKED` is supposed to avoid contention.  But in practice, with many concurrent workers all racing to lock rows, there are brief windows where multiple transactions reference the same row before one of them "wins" and the others skip.  If you combine this with any `FOR SHARE` or `FOR KEY SHARE` locks (which are commonly created implicitly by foreign key checks), MultiXact IDs start accumulating quickly.

The MultiXact data lives in SLRU buffers (Simple Least Recently Used) -- a small, fixed-size shared memory cache.  When backends need to read or write MultiXact data, they acquire LWLocks to access these buffers.  Under high concurrency, this becomes a bottleneck:

```
wait_event_type | wait_event
-----------------+-------------------
LWLock          | MultiXactMemberSLRU
LWLock          | MultiXactOffsetSLRU
```

You'll see dozens or hundreds of backends piled up on these waits.  The SLRU cache is small (by design -- it's a fixed number of pages in shared memory), and when the working set of MultiXact lookups exceeds what fits in the cache, you get constant eviction and re-reads from disk.  Every lock acquisition and release on a job row potentially triggers a MultiXact SLRU lookup, and at thousands of concurrent sessions, those lookups serialize on LWLocks.

The result: CPU gets pegged, throughput collapses, and latency spikes -- not because the queries are expensive, but because the locking infrastructure itself is overwhelmed.

---

## Bloat: The Silent Killer

The other side of this coin is table and index bloat.  Every job row goes through multiple updates (and possibly a delete), and each of those operations creates a new tuple version in the heap.  The old versions stick around until `VACUUM` cleans them up.

On a busy job queue table:

- **Dead tuples accumulate faster than autovacuum can clean them.**  By the time autovacuum finishes one pass, tens of thousands of new dead tuples have appeared.  The table grows and grows.
- **Index bloat compounds the problem.**  Every index on the table also accumulates dead entries.  The partial index on `status = 'pending'` gets thrashed especially hard, since rows constantly enter and leave that condition.
- **Sequential scans get slower.**  As the table bloats, even index scans start doing more I/O because the heap pages are sparsely populated.  Vacuum reclaims space at the end of the table, but can't reclaim space in the middle (unless the pages are completely empty).

Job queue tables can grow to tens of gigabytes when the actual "live" data was only a few megabytes.  It makes everything slower: scans, vacuum, even `pg_dump`.

You can mitigate this by running vacuum more aggressively (lower `autovacuum_vacuum_scale_factor`, higher `autovacuum_vacuum_cost_limit`), or by partitioning the table and dropping old partitions.  But at some point, you're fighting the fundamental mismatch between MVCC's design goals and the write pattern of a job queue.

---

## CPU and Lock Overhead

Beyond the SLRU contention and bloat, there's just the raw overhead of using Postgres's full transactional machinery for what is essentially a FIFO dispatch operation:

1. **Every lock/unlock is a full WAL-logged transaction.**  Grabbing a job writes WAL.  Marking it complete writes WAL.  Deleting it writes WAL.  On a system processing thousands of jobs per second, the WAL volume from the job queue alone can saturate your `wal_writer` and checkpoint processes.

2. **`SKIP LOCKED` still touches rows.**  The name suggests rows are skipped, but Postgres still has to *find* them, check their lock status, and move on.  With high concurrency, many workers end up scanning past the same locked rows before finding one they can claim.  This is wasted CPU.

3. **Snapshot management overhead also becomes an issue.**  Each transaction needs a consistent snapshot, and with thousands of concurrent transactions, the ProcArray (the structure that tracks active transactions) becomes a contention point itself.  You might see `LWLock:ProcArrayLock` waits alongside the MultiXact ones.

4. **Vacuum contention.**  While vacuum is cleaning up dead tuples, it needs locks too.  On a table under constant write pressure, vacuum can interfere with the workers and vice versa.  I've seen systems where disabling autovacuum on the job queue table improved throughput in the short term.

---

## Better Alternatives

So what should you use instead?  It depends on your requirements, but there are several options that handle high-throughput job dispatch more gracefully than a Postgres table.

### Advisory Locks (Staying in Postgres)

If you want to stay within Postgres and avoid adding infrastructure, advisory locks are worth considering for certain queue patterns.  Instead of locking rows, you lock on an abstract numeric key:

```sql
-- Worker tries to acquire a lock on the job ID
SELECT pg_try_advisory_lock(id) FROM job_queue
 WHERE status = 'pending'
 ORDER BY created_at
 LIMIT 1;
```

Advisory locks are lightweight -- they don't touch the heap, don't create MultiXact entries, and don't generate dead tuples.  They live entirely in shared memory.  The trade-off is that you lose the atomicity of `FOR UPDATE SKIP LOCKED`: you need to handle the case where a lock is acquired but the job processing fails, and you need to release the lock explicitly (or rely on session-end cleanup).

This approach works well when the queue depth is manageable and you want to avoid the MVCC overhead.  But it's still Postgres, so you're still subject to connection limits, ProcArray overhead, and general resource contention at very high session counts.

### pgq (Skytools)

pgq is purpose-built for exactly this problem.  It's a queue implementation that sits inside Postgres but uses a batching model that avoids most of the row-level locking and MVCC pitfalls.  Events are written to a queue table, but consumers read them in batches and the queue maintenance is done via a ticker process that manages rotation.

The key advantages:
- No row-level contention.  Consumers don't lock individual rows.
- Built-in batch processing.  Events are consumed in chunks, reducing transaction overhead.
- Efficient cleanup.  Old events are rotated out rather than vacuumed row-by-row.

The downside is that pgq is not as actively maintained as it once was, and it adds operational complexity (the ticker daemon, consumer registration, etc.).  But for teams already deep in the Postgres ecosystem, it's a battle-tested option.

### PgQue

Coincidentally, during the writing of this post, [Nikolay Samokhvalov has built PgQue](https://github.com/NikolayS/pgque), which is a derivative of pgq.  Like pgq, it sits inside Postgres, but ships as a single SQL file -- no C extension and no external daemon -- making it deployable on managed services like RDS, Aurora, Cloud SQL, AlloyDB, Supabase, and Neon.  Producers `INSERT` events into rotating event tables (recycled via `TRUNCATE` instead of row-by-row deletion), and consumers read batches by diffing two `pg_snapshot` values captured by a periodic ticker -- so the hot path contains zero `UPDATE`s, `DELETE`s, or `SELECT ... FOR UPDATE SKIP LOCKED`, and therefore produces no dead tuples on the event tables.  For a deeper dive into the algorithm, see [Christophe Pettus's writeup](https://thebuild.com/blog/2026/05/03/pgque-two-snapshots-and-a-diff/).

### Redis

For many teams, Redis is the natural choice for job queues.  Using Redis lists (BRPOPLPUSH or the Streams API), you get:

- Sub-millisecond dispatch latency.  No disk I/O, no MVCC, no vacuum.
- Atomic pop operations.  Workers grab jobs without any locking protocol.
- Simple scaling.  Redis handles thousands of concurrent consumers trivially.

The trade-off is durability.  Redis can persist to disk, but it's not ACID.  If Redis crashes between a pop and the job completing, you might lose or duplicate work (though Redis Streams with consumer groups mitigate this significantly).  For most job queue use cases, at-least-once delivery is acceptable, and Redis does that well.

### Kafka

For truly high-throughput, distributed workloads, Apache Kafka is the heavyweight option.  Kafka partitions give you parallel consumption with ordering guarantees per partition, durable storage, and replay capability.  It's the right tool when:

- You need to process thousands of events per second
- Multiple consumers need to read the same events
- You want event replay or audit trails
- Your architecture is already event-driven

The operational overhead is nontrivial -- ZooKeeper (or KRaft), brokers, topic management, consumer group coordination.  But for teams already running Kafka for other reasons, adding a job queue topic is practically free.

---

## Choosing the Right Tool

Here's a rough decision guide:

| Scenario | Recommendation |
|---|---|
| Under 100 concurrent workers, simple jobs | Postgres with `SKIP LOCKED` is fine |
| Moderate concurrency, want to stay in Postgres | Advisory locks or pgq |
| High throughput, low-latency dispatch | Redis (Lists or Streams) |
| Massive scale, distributed, event replay | Kafka |

Many teams that start with Postgres (reasonably) hit scaling problems and then try to fix Postgres rather than recognizing that the workload has outgrown the tool.  They throw more autovacuum workers at it, increase `max_connections`, add connection poolers -- all of which help at the margins, but don't address the fundamental issue: Postgres's MVCC and locking machinery wasn't designed for this access pattern at high concurrency.

---

## Conclusion

Postgres is great, but it can't be the best tool for every job.  Using it as a job queue is a perfectly valid choice when your scale is modest.  But when you're running thousands of concurrent workers, the combination of MultiXact SLRU contention, heap bloat, vacuum pressure, and raw locking overhead will eventually push you toward a purpose-built solution.

The good news is that you don't have to rip out everything.  Advisory locks can buy you headroom without adding infrastructure.  Redis can handle dispatch while Postgres keeps owning the data.  And if you're already using Kafka, a job topic is a natural fit.  Take your pick -- there are many queueing options out there!
