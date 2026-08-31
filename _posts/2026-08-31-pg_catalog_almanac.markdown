---
layout: post
title:  "pg-catalog-almanac"
date:   2026-08-31 00:00:00 -0800
tags: PostgreSQL postgres system-catalogs pg-catalog internals tooling
comments: true
categories: postgres
---

### Did you know: PG19 is on track to contain the most changes to `pg_catalog` in history
# Introduction

`pg_catalog` is one of the most important interfaces PostgreSQL gives us: it exposes the metadata that describes database structure -- tables, columns, indexes, constraints, types, and dependencies -- alongside views into what the server is doing right now.  When diagnosing replication lag, long-running or blocked queries, idle transactions, lock contention, vacuum activity, and other real-time performance problems, `pg_catalog` is often where I'm spending my time poking around.

Every so often, working with those catalogs leads me to a question that sounds like it should have a quick answer:

> I wonder when that changed.

When was `leader_pid` added to `pg_stat_activity`?  Has `pg_locks` always had `waitstart`?  Which catalogs and views will be new in PostgreSQL 19?

Those answers are available in the PostgreSQL documentation, tracking changes over time isn't very trivial.  Opening the documentation for several releases, comparing tables, and then checking release notes to understand what happened -- this can get tedious very quickly.

I wanted something simpler, and [pg-catalog-almanac](https://richyen.com/pg-catalog-almanac/), a browsable representation of the PostgreSQL documentation for `pg_catalog` hopefully accomplishes that.

![pg-catalog-almanac-home](https://raw.githubusercontent.com/richyen/pg-catalog-almanac/main/docs/home.png)

---

# Inspiration

[postgresqlco.nf](https://postgresqlco.nf/) is my favorite PostgreSQL reference outside of the official documentation.  It makes the history of configuration parameters easy to explore: choose a setting, see the versions, and quickly understand how it evolved.  And then there are useful links to articles as well.

I wanted that same experience for PostgreSQL's system catalogs, system views, and statistics views. `pg-catalog-almanac` may not be as feature-rich as `postgresqlco.nf` but I hope it gets close -- it currently covers all 143 documented relations across PostgreSQL 9.6 through the upcoming PostgreSQL 19.

---

# Some Interesting Discoveries

Once I got the versions placed next to each other, I found these observations to be somewhat interesting.  Might not be interesting to others, but it got my attention!

## 1. PostgreSQL 19 Has the Most New Relations in the Dataset

As of PostgreSQL 19 beta 3, the upcoming release adds **12 catalogs and views** and **43 columns**.  That is the largest number of new relations in any release after the PostgreSQL 9.6 baseline.  PostgreSQL 10 is the next closest with 11.

Five of the new catalogs support SQL property graphs: `pg_propgraph_element`, `pg_propgraph_element_label`, `pg_propgraph_label`, `pg_propgraph_label_property`, and `pg_propgraph_property`.

![what-changed-in-pg19](https://raw.githubusercontent.com/richyen/richyen.github.io/refs/heads/gh-pages/img/what-changed-in-pg19.png)

There are also several operationally interesting additions: `pg_stat_lock`, `pg_stat_recovery`, and `pg_stat_autovacuum_scores`, along with progress views for `REPACK` and online data checksum changes.  At a glance, PostgreSQL 19 looks like a significant expansion in both SQL features and operational visibility.

## 2. Only One Entire Relation Has Ever Been Removed

Across all tracked transitions from PostgreSQL 9.6 through 19, only one relation disappears completely: [`pg_pltemplate`](https://richyen.com/pg-catalog-almanac/#/r/pg_pltemplate).

It is present through PostgreSQL 12 and gone in PostgreSQL 13.  `pg_pltemplate` held template information used when creating procedural languages.  PostgreSQL 13 introduced trusted extensions and moved procedural-language installation onto the normal extension machinery, removing the need for that special catalog.


## 3. Collation Metadata Shows an Abstraction Evolving

The histories of [`pg_collation`](https://richyen.com/pg-catalog-almanac/#/r/pg_collation) and [`pg_database`](https://richyen.com/pg-catalog-almanac/#/r/pg_database) capture PostgreSQL's expanding collation support through a handful of small catalog changes.

In PostgreSQL 15, `pg_collation.collcollate`, `pg_collation.collctype`, `pg_database.datcollate`, and `pg_database.datctype` changed from `name` to `text`.  Locale values are not identifiers, and `text` permits customized ICU locale names longer than the 63-byte identifier limit while also saving space for typical short locale names.

Then PostgreSQL 17 added a built-in, platform-independent collation provider.  The ICU-specific `colliculocale` and `daticulocale` names became the provider-neutral `colllocale` and `datlocale`.

![pg-collation-changes](https://raw.githubusercontent.com/richyen/richyen.github.io/refs/heads/gh-pages/img/pg-collation-changes.png)

---

# Conclusion

While my main motivation was to document and understand upcoming and past changes to `pg_catalog` for some of my projects, I can see this being useful for DBREs and software engineers who are planning upgrades and need to tweak monitoring queries, ORMs, APIs, and so on.  I hope that people can find it useful, making some aspects of DB-related research less tedious and time-consuming