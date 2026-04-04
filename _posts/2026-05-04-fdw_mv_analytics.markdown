---
layout: post
title: "Foreign Tables and Materialized Views: A Dynamic Duo"
date: 2026-05-04 00:00:00 -0800
categories: postgres fdw analytics performance architecture
comments: true
categories: postgres
---

## Introduction

I recently wrote a post about [WAL log shipping](/postgres/2026/04/06/wal_archiving.html) and how a standby built on log shipping is a great way to give data analysts production data without putting the primary at risk.  Having access to the production data in this way is great, but it's read-only.  How can we create views of this data for better analytics work?  I want to make the case today that Foreign Data Wrappers and Materialized Views can make a great solution -- not only in accessing production Postgres data, but also working with other data sources.

---

## Moving Beyond FDW Demos

Most people meet foreign data wrappers (FDWs) through a quick demo, and I've [highlighted some of their features in previous conference talks](https://speakerdeck.com/richyen/2023-pgday-chicago-fdw).  There is high novelty in being able to query MySQL from Postgres, but the reality is often that the latency between the local database and the foreign table can be pretty high.  Sometimes, predicate push-down isn't what you'd expect, and indexing may not be very transparent.  In the end, setting up and managing FDWs may seem more work than it's worth, and that's a mistake.  Used correctly, foreign tables are one of the most practical tools for **analytics across heterogeneous data sources** -- especially when paired with materialized views.

---

## The Real Problem: Heterogeneous Data

Modern data rarely lives in one place:

- Legacy systems in MySQL
- Operational data in PostgreSQL
- Flat files sitting in object storage (I've seen people do this with AWS Athena)
- Maybe even some CSVs someone refuses to migrate

Foreign tables give you a unified SQL interface, but under the hood, the query performance can be unpredictable as you may be forced to rely on another engine's query planner (and in the case of that CSV data source, it might not even be indexed).

In other words, FDWs optimize developer experience, not query performance.

---

## The Pattern: FDW + Materialized Views

Instead of querying foreign tables directly in analytics workloads, we can opt to use FDWs as ingestion points, not as the serving layer itself.  To achieve this, we can do the following:

### Step 1: Define the foreign table

```sql
CREATE FOREIGN TABLE ext_orders (
  id bigint,
  customer_id bigint,
  total numeric,
  created_at timestamp
)
SERVER mysql_server
OPTIONS (table 'orders');
```

### Step 2: Build a materialized view

```sql
CREATE MATERIALIZED VIEW orders_mv AS
SELECT
  id,
  customer_id,
  total,
  created_at::date AS order_date
FROM ext_orders;
```

### Step 3: Index it like a real table

```sql
CREATE INDEX ON orders_mv (order_date);
CREATE INDEX ON orders_mv (customer_id);
```

Now we’ve turned a slow, remote dataset into a locally optimized analytical structure.

The materialized view lives inside PostgreSQL, supports full indexing, eliminates network latency during queries, and gives predictable performance.  We essentially have a read-optimized cache on top of the foreign tables.  We can do this with the read-only Postgres replicas as well, to slice up the columns and rows to fit nicely in a view that analysts would want to use.

---

## Refreshing Without Blocking

When it comes to caching, data gets stale, and we're sort of back at the same problem every ETL pipeline faces.  However, Postgres can refresh a materialized view without blocking users, simply with the `CONCURRENTLY` syntax.  This results in production-quality data with a little bit of staleness, but the nice thing is that it's all built-in to the Postgres cluster (no separate ETL pipeline to manage, just all the data accessible from one central place).  Note, however that in order to use the `CONCURRENTLY` syntax, [a `UNIQUE` key is required](https://www.postgresql.org/docs/current/sql-refreshmaterializedview.html).

---

## Good Applications for the Pairing

The pairing of FDWs and indexed Materialized Views could be very beneficial in a handful of use cases:

### 1. Poorly Indexed Remote Systems

If your upstream system:
- Lacks proper indexes
- Is shared with OLTP workloads
- Is not under your control

This approach isolates analytics from those constraints.

### 2. High-Latency Data Sources

Examples:
- Cross-region databases
- Cloud object storage via FDWs
- Athena-backed datasets

Instead of paying the latency cost on every query, you pay it once per refresh.

### 3. Flat Files and Large Data

Yes, people do this:
- Querying CSVs via FDWs
- Treating object storage as a “database”
- Large JSONB sets that are hard to index well

---

## Final Thoughts

Foreign tables aren’t just novelty -- they’re a powerful bridge across messy, real-world data systems.

It is important to distinguish that FDWs make a **data access layer**, while Materialized Views are the **analytics engine**.  If you 1) layer materialized views on top of FDWs, 2) add proper indexing, and 3) refresh intelligently (preferably concurrently), you can get the best of both worlds: flexibility of federated queries and performance of local analytics.
