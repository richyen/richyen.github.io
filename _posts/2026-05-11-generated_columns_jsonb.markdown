---
layout: post
title:  "Making JSONB More Queryable with Generated Columns"
date:   2026-05-11 00:00:00 -0600
tags: PostgreSQL postgres jsonb generated columns indexing performance
comments: true
categories: postgres
---

## Introduction

Over the past year, I've worked in a handful of contexts managing large volumes of data stored as JSONB in PostgreSQL. The scenario is common: users appreciate the flexibility of a document-oriented storage model, avoiding the need to predefine schemas or constantly migrate table structures as their data requirements evolve. JSONB documents can be deeply nested with numerous optional fields, and they scale to hundreds of kilobytes per record without issue. However, when the time comes to query these documents -- filtering by user ID, event type, timestamps, or nested action properties -- the queries can become slow and/or cumbersome to work with.

The problem I want to address is: "How do we make searching JSONB data more efficient without breaking apart our documents or forcing it into columns in a relational database?" There are several approaches available in Postgres, each with different tradeoffs. I hope to shed some light on those approaches in this article.

## The Setup

I created a basic, no-frills table for the sake of this test:

```sql
CREATE TABLE events (
    id BIGSERIAL PRIMARY KEY,
    data JSONB NOT NULL
);

Here's the document shape I used for testing and writing this post -- it's representative of the event logs and audit trails I've encountered: a mix of primitive fields, nested objects, and metadata that accumulates over time.

-- Representative JSONB document
{
  "user_id": 5234,
  "event_type": "event_42",
  "timestamp": 1712341200,
  "session_id": "sess_abc123...",
  "ip_address": "192.168.1.42",
  "action": {
    "type": "click",
    "target_id": 87654,
    "coordinates": {"x": 512, "y": 768},
    "duration_ms": 1234
  },
  "device": {
    "type": "mobile",
    "os": "iOS",
    "screen_width": 1920,
    "screen_height": 1080
  },
  "performance": {
    "page_load_time": 1234,
    "dns_lookup": 123,
    "tcp_connection": 234,
    "server_response": 876
  },
  "custom_fields": { ... }
}
```

The queries that matter are straightforward equality and range filters on known fields: find all events for a given user, filter by event type, narrow to a time window. With this setup, we'll try to discern which kind of index actually serves the specific access pattern, and what the real cost of each option is.

*All tests run on PostgreSQL 18.2 in Docker on an Apple M-series host. Tables contain 50,000 rows with realistic JSONB event documents. Query benchmarks run 20 times on a warm cache and report avg/min/max. Insert benchmarks run 5 trials of 5,000 rows each. Schema and scripts are included throughout so you can reproduce these results.*

## Three Approaches to Indexing JSONB

There are three realistic options for this access pattern. Let's look at each in turn -- what it costs to build/maintain, what queries it actually helps, and where it falls down.

### Option 1: GIN Indexes

The natural candidate for indexing a JSONB column would be a GIN (Generalized Inverted Index) index.  After all, GIN indexes are specifically designed for JSON documents and full-text search.  It indexes every key and value pair in every document, making the entire structure searchable:

```sql
CREATE INDEX idx_gin ON events USING GIN (data);
-- or the path-only variant:
CREATE INDEX idx_gin_path ON events USING GIN (data jsonb_path_ops);
```

As a refresher, I'll mention that GIN is designed for containment and key existence operators (`@>`, `?`, `?|`, `?&`), not for equality on extracted fields:

```sql
-- This query uses a GIN index correctly:
SELECT id FROM events WHERE data @> '{"user_id": 5234}';

-- This query does NOT use a GIN index, even if one exists:
SELECT id FROM events WHERE cast(data->>'user_id' AS INT) = 5234;
```

For the containment form, the GIN index is used and the query is fast -- but still slower than a B-tree on the same field, because GIN lookups involve more bookkeeping:

```
-- GIN jsonb_ops + containment operator
Bitmap Index Scan on idx_gin
  Index Cond: (data @> '{"user_id": 5234}')

lanning Time: 1.173 ms  |  Execution Time: 1.295 ms

-- GIN jsonb_path_ops + containment operator
Bitmap Index Scan on idx_gin_path
  Index Cond: (data @> '{"user_id": 5234}')
Planning Time: 3.342 ms  |  Execution Time: 0.450 ms
```

The `jsonb_path_ops` variant is smaller and faster for containment queries, but it trades away support for key-existence operators (`?`, `?|`, `?&`). Neither GIN variant can help with range predicates like `ts > 1700000000` -- those always fall through to a filter step.

### Option 2: Expression Indexes

Postgres lets you create an index on an expression, including JSONB extraction:

```sql
CREATE INDEX idx_user_id ON events (cast(data->>'user_id' AS INT));
```

This is a B-tree index on the *result* of evaluating the expression. When the query predicate matches the indexed expression exactly, and after `ANALYZE` has gathered statistics on it, the planner will use it:

```sql
SELECT id FROM events
WHERE cast(data->>'user_id' AS INT) = 5234;
```

```
Bitmap Heap Scan on t_expr
  Recheck Cond: ((data ->> 'user_id')::integer = 5234)
  Heap Blocks: exact=3
  ->  Bitmap Index Scan on idx_user_id
        Index Cond: ((data ->> 'user_id')::integer = 5234)
Planning Time: 1.168 ms  |  Execution Time: 0.341 ms
```

The execution time on this equality operator seems to be pretty similar to the performance of the GIN index.

### Option 3: Generated Columns

Generated columns (available since PostgreSQL 12) let you extract JSONB values into regular typed columns at write time. The values are stored physically alongside the row and kept in sync automatically:

```sql
CREATE TABLE events (
    id         BIGSERIAL PRIMARY KEY,
    data       JSONB NOT NULL,
    user_id    INT    GENERATED ALWAYS AS ((data->>'user_id')::INT)    STORED,
    event_type TEXT   GENERATED ALWAYS AS (data->>'event_type')        STORED,
    ts         BIGINT GENERATED ALWAYS AS ((data->>'timestamp')::BIGINT) STORED,
    action     TEXT   GENERATED ALWAYS AS (data->'action'->>'type')    STORED
);

CREATE INDEX idx_user_id ON events (user_id);
CREATE INDEX idx_event_type ON events (event_type);
CREATE INDEX idx_ts ON events (ts);
CREATE INDEX idx_action ON events (action);
```

Queries against generated columns are plain typed-column lookups. The planner sees them as regular B-tree columns and produces tight estimates:

```sql
SELECT id FROM events WHERE user_id = 5234;
```

```
Bitmap Heap Scan on t_gen
  Recheck Cond: (user_id = 5234)
  Heap Blocks: exact=3
  ->  Bitmap Index Scan on idx_user_id
        Index Cond: (user_id = 5234)
Planning Time: 1.159 ms  |  Execution Time: 0.407 ms
```

You also get native support for range queries and composite indexes at no extra complexity -- just combine columns as you normally would:

```sql
-- Indexed range query on generated timestamp column
CREATE INDEX ON events (event_type, ts);

SELECT id FROM events
WHERE event_type = 'event_42' AND ts > 1700000000;
-- Execution Time: 0.698 ms (vs 6.6 ms with GIN + post-filter)
```

## Side-by-Side: Query Performance

With all three approaches set up, here are the warm-cache query results averaged over 20 runs for an equality filter on `user_id`:

| Approach | Avg (ms) | Min (ms) | Max (ms) |
|---|---|---|---|
| GIN jsonb_ops + `@>` | 0.198 | 0.101 | 1.769 |
| GIN jsonb_path_ops + `@>` | 0.197 | 0.032 | 3.115 |
| Expression index | 0.106 | 0.018 | 1.705 |
| Generated column B-tree | 0.112 | 0.016 | 1.839 |

Expression indexes and generated columns perform very similarly for equality queries—both around 0.1ms on warm cache. The real work is done in the B-tree lookup and both produce the same index structure. GIN with the correct `@>` operator is nearly as fast in PG 18.2 -- still slightly slower than B-tree for this access pattern, but the gap has narrowed. GIN lookups still require a recheck step that B-tree lookups avoid, and the variance remains notable: GIN max of 3.1ms vs B-tree max of 1.8ms on warm cache.

The more surprising result is what happens if the GIN index is present but the query is written with extraction-based equality:

```sql
-- GIN index exists, but this query gets a seq scan:
SELECT id FROM events WHERE cast(data->>'user_id' AS INT) = 5234;
-- Execution Time: 47.935 ms (same as no index at all)
```

GIN doesn't support that operator class. This is by far the most common confusion teams run into with JSONB indexing.

## The Full Cost Picture: Storage and Writes

### Storage

Here's what the same 50,000 rows cost on disk under each approach:

| Approach | Table size | Index size | Total |
|---|---|---|---|
| Expression indexes (4) | 18 MB | 3.5 MB | 21 MB |
| Generated columns + B-tree (4) | 20 MB | 3.5 MB | 23 MB |
| GIN jsonb_path_ops | 18 MB | 13 MB | 31 MB |
| GIN jsonb_ops | 18 MB | 18 MB | 36 MB |

Expression indexes and generated column B-tree indexes produce *identical* index sizes for the same fields -- this makes sense, since the index structures are the same; the only extra cost of generated columns is the 2 MB of additional stored column data in the table (~40 bytes per row for four typed columns). GIN indexes are substantially larger: 13–18 MB for a single index vs 3.5 MB for four targeted B-tree indexes. The `jsonb_path_ops` variant is smaller because it only stores value hashes for the `@>` operator path, but it still dwarfs the targeted approach.

One caveat: these numbers reflect documents with short keys and compact values. Documents with verbose key names, deeply nested structures, or large string values will inflate GIN indexes proportionally more -- because GIN indexes every key path. B-tree and expression indexes are unaffected by document verbosity, since they only store the extracted value.

### Write Throughput

Here's what 5,000 INSERTs per trial, 5 trials each, on a table already containing 50,000 rows looked like:

| Approach | Avg (ms) | Min (ms) | Max (ms) |
|---|---|---|---|
| Generated columns + B-tree (4) | 157 | 91 | 317 |
| Expression indexes (4) | 163 | 93 | 366 |
| GIN jsonb_path_ops | 171 | 73 | 408 |
| GIN jsonb_ops | 334 | 225 | 525 |

Generated columns and expression indexes are now very close in write cost, with generated columns slightly edging out on average. GIN jsonb_path_ops has become more competitive with both. However, the default GIN jsonb_ops variant is dramatically more expensive: 2× slower than expression indexes and generated columns. It must decompose the entire document into key-value pairs and insert entries for each one. The high variance is also worth noting: GIN jsonb_ops max of 525ms vs 366ms for expression indexes. 

## Choosing the Right Approach

The benchmarks above tell a consistent story for workloads dominated by equality and range filters on a known set of fields:

- **Expression indexes** are the lowest-cost migration path. They add no schema structure, require no application changes to insert logic, and impose minimal write overhead. If your team already has a table in production and just needs to speed up a handful of known slow queries, a well-placed expression index is your first move. The catch: every query must exactly match the expression as written in the index definition, which can be fragile to maintain as codebases evolve.

- **Generated columns** take slightly more storage and impose more write overhead than expression indexes, but they offer something the others can't: the extracted values become first-class columns. You can build composite indexes across them, reference them in views, expose them via ORMs, and sort or aggregate on them without embedding extraction logic everywhere. For new tables or for tables you're willing to migrate, they're the most maintainable long-term solution.

- **GIN indexes** serve a different purpose. They're the right tool when your query patterns are flexible or unknown -- searching for the existence of a key, filtering on any field in an ad-hoc fashion, or supporting containment queries on arbitrarily-shaped documents. For those access patterns, they're genuinely powerful and there's no clean B-tree equivalent. But for consistent equality and range filters on known fields, they cost more in storage, impose higher write latency, and only work with one operator class (`@>`, not `=`).

Here's a rough decision guide:

| Situation | Recommended approach |
|---|---|
| Unknown or ad-hoc field queries | GIN (`@>`, key existence) |
| Known fields, few queries, no schema change | Expression index |
| Known fields, high query volume, evolving codebase | Generated columns |
| Known fields + range queries (e.g., timestamps) | Generated columns + composite B-tree |
| Mixed: some known fields + some ad-hoc | Generated columns + GIN (both) |

## Caveats and Considerations

Regardless of which approach you choose, a few things apply broadly:

**The real win is making data typed and relational again.** Generated columns aren't magic. The reason they (and expression indexes) outperform GIN for equality filters is that they produce typed scalar values with precise statistics, letting the planner make accurate row-count estimates and choose cheap comparison operations. JSONB is flexible but opaque; once you extract a field into a typed column or expression, Postgres can reason about it properly.

**Expression indexes require exact predicate matching.** An index on `cast(data->>'user_id' AS INT)` will not be used by a query written as `(data->>'user_id')::int`. The cast form must be identical. Generated columns avoid this fragility -- any query that references the column name will benefit.

**Generated column expressions must be immutable.** The expression cannot reference functions that depend on time, session state, or anything external. `NOW()`, `CURRENT_USER`, and similar functions are off-limits.

**Generated columns cannot be directly updated.** Their value is always derived from the source column. If you UPDATE the JSONB `data`, the generated columns recompute automatically.

**GIN maintenance overhead compounds on write-heavy tables.** GIN indexes build an internal pending list and flush it periodically (controlled by `gin_pending_list_limit`). Under sustained write load, this flushing can cause the latency spikes visible in the benchmark max values above. B-tree indexes don't have this mechanism.

**These benchmarks cover one dataset shape and one machine.** At much larger row counts (hundreds of millions), cache-miss behavior and index bloat will dominate—relative rankings should hold, but absolute numbers will differ. When in doubt, benchmark on your own data before committing to a migration.

## Conclusion

For workloads dominated by equality and range filters on a predictable set of JSONB fields, the data is clear: B-tree indexes on typed values -- whether via expression indexes or generated columns -- outperform GIN both on read latency and write throughput. GIN's strength is flexibility, not speed for known-field access patterns; when you know exactly which fields you'll filter on, a targeted B-tree beats the GIN every time.

If you're starting from scratch or are willing to migrate a table, generated columns are the most maintainable path. They make your frequently-queried fields easily accessible, eliminate JSONB extraction logic from your application's query layer, and support composite indexes and range queries naturally. If you need to add indexing to an existing table without a schema change, expression indexes get you 90% of the way there with a fraction of the write overhead.

GIN still belongs in your toolkit -- but for the right job: ad-hoc containment searches, key-existence checks, and cases where the query patterns genuinely vary by document. For everything else, make your JSONB fields relational.