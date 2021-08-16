---
layout: post
title:  "How to See Inherited Permissions for a User"
date:   2021-08-16 09:00:00 -0800
tags: PostgreSQL postgres permissions inheritance privileges acl access
comments: true
categories: postgres
---

# Introduction
I recently had a customer case where a developer was trying to inspect the privileges granted to a specific user.  We attempted to look in `information_schema.table_privileges` but quickly discovered that it only printed the interpreted contents of `relacl` in `pg_class` -- in other words, `information_schema.table_privileges` does not print permissions inherited by group membership.

# The Query
To view inherited permissions, we leveraged PostgreSQL's `has_table_privilege()` function, one of [several permissions-related functions listed in the documentation](https://www.postgresql.org/docs/current/functions-info.html).  With that, we formulated the following query:

```
SELECT r.rolname AS user_name,
       c.oid::regclass AS table_name,
       p.perm AS privilege_type
  FROM pg_class c CROSS JOIN
       pg_roles r CROSS JOIN
	   unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p(perm)
 WHERE relkind = 'r' AND
       relnamespace NOT IN (SELECT oid FROM pg_namespace WHERE nspname in ('pg_catalog','information_schema')) AND
       has_table_privilege(rolname, c.oid, p.perm);
```

This query will list every user and *ALL* the non-system tables they have privileges for, with one row for each privilege -- this could be overwhelming to someone looking for information on just one user or one table.  To filter the results, one can add an `AND` condition on `rolname` and/or `relname`.

Enjoy!
