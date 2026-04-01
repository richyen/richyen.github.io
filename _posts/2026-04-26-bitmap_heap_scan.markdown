---
layout: post
title:  "Understanding Bitmap Heap Scans in PostgreSQL"
date:   2026-04-26 00:00:00 -0800
tags: PostgreSQL postgres performance query-planner indexing
comments: true
categories: postgres
---

# Introduction

When people first start reading PostgreSQL execution plans, they quickly learn a few common scan types: `Seq Scan`, `Index Scan`, `Index Only Scan`.  But eventually another one appears that is less obvious: `Bitmap Heap Scan`, which is almost always accompanied by `Bitmap Index Scan`.

At first glance, it sounds like two scans on the same table -- a very inefficient choice?! But bitmap scans are actually one of the planner’s most practical tools for balancing random I/O vs sequential access.  Understanding how they work can make execution plans much easier to interpret, so we'll dive into that a little bit today.

---

# The Basic Idea

A bitmap scan is a two-step process:

Step 1: Build a bitmap of matching rows using one or more indexes.

Step 2: Visit the heap pages containing those rows referenced in the bitmap.

In an execution plan this usually appears as:

```
Bitmap Heap Scan on orders
-> Bitmap Index Scan on orders_customer_id_idx
```

The important part is that the index lookup and heap access are separated -- this separation allows the Postgres to explain heap access costs and actuals more clearly.

---

# Why Not Just Use an Index Scan?

With a normal index scan, the query executor does something like this:

1. Find a matching entry in the index
2. Jump to the heap page
3. Fetch the row
4. Repeat

If the query returns only a few rows, this works well.  But if the query returns thousands of rows scattered across the table, the database ends up doing many random heap fetches.  Random I/O can become expensive, so a bitmap scan solves this problem.

---

# How the Bitmap Is Built

During the Bitmap Index Scan phase, the executor does not immediately fetch rows.  Instead it records which heap pages contain matching rows.  Conceptually, the structure looks like this:

```
Page 101 -> rows 2, 7
Page 205 -> rows 1, 3, 8
Page 410 -> row 5
```

These page references are stored as a bitmap structure in memory.  Once the bitmap is complete, the executor can visit heap pages in physical order rather than jumping around randomly.  Visiting heap pages in physical order means less random I/O and therefore less latency.

---

# Multiple Indexes Can Be Combined

One particularly powerful feature is that bitmap scans allow the query planner to combine multiple indexes.  For example:

```
WHERE status = 'active'
AND created_at >= '2025-01-01'
```

The plan might look like:

```
Bitmap Heap Scan
-> BitmapAnd
-> Bitmap Index Scan on status_idx
-> Bitmap Index Scan on created_at_idx
```

Each index produces a bitmap, and the planner combines them using logical operations, such as `BitmapAnd` and `BitmapOr`.  This allows the planner to efficiently use multiple indexes even when a single composite index does not exist.

---

# When Does the Planner Chooses Bitmap Scans?

The planner usually prefers bitmap scans in situations where the query returns more rows than a typical index scan, but not enough rows to justify a full sequential scan.  In other words, bitmap scans often appear in the middle selectivity range.

Very roughly:

| Selectivity | Likely Plan |
|--------------|-------------|
| Very small | Index Scan |
| Medium | Bitmap Heap Scan |
| Very large | Seq Scan |

This is not a strict rule, but it helps explain the planner’s reasoning.

---

# Pros and Cons

As with everything in databases, there's no free lunch.  Here are some advantages and disadvantages for bitmap scans

- Advantages of Bitmap Heap Scans
  - Reduced Random I/O: By grouping heap page accesses, bitmap scans avoid excessive random disk reads.
  - Ability to Combine Indexes: Bitmap operations allow the query planner to use multiple independent indexes efficiently.
  - Better Performance for Medium Selectivity: Queries returning thousands of rows often benefit from bitmap access patterns.
  - Predictable Heap Access: Because heap pages are visited in order, caching behavior tends to improve.
- Disadvantages of Bitmap Heap Scans
  - Memory Usage: The bitmap structure is stored in memory.  If the result set becomes too large, the query executor may switch to a lossy bitmap, where only page-level information is stored.  This can cause additional filtering work later.
  - Two-Phase Execution: Because the bitmap must be built before heap access begins, the query cannot stream rows immediately.  This can increase latency for queries expecting early rows.
  - Extra CPU Work: Maintaining and combining bitmap structures adds overhead compared to simple index scans.

---

# Lossy Bitmaps

When memory limits are reached, the query executor may degrade the bitmap representation.  Instead of tracking individual tuple offsets, it only records:

```
Page 205 -> possible matches
```

During the heap scan, the executor must then recheck all rows on that page.  In execution plans you may see mention of `Recheck Cond`.  This indicates that the bitmap became lossy.  While still correct, this can reduce efficiency.

---

# Final Thoughts

Bitmap heap scans are one of the planner’s most practical optimization tools, as they allow the database to reduce random I/O, combine multiple indexes, handle medium-sized result sets efficiently.

While they may look complicated at first, the core idea is simple:Find matching rows first, then fetch heap pages efficiently.  What a great concept!
