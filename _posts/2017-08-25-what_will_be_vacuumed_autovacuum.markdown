---
layout: post
title:  "What tables will be vacuumed at the next autovacuum cycle?"
date:   2017-08-25 13:01:09 -0800
tags: autovacuum vacuum maintenance PostgreSQL postgres
comments: true
categories: postgres
---

# Introduction
Someone recently asked me if there was a way to tell which table(s) are slated for `VACUUM` at the next autovacuum cycle.  I couldn't find any results after a short search on Google, so I decided to come up with my own query.  [According to source](https://github.com/postgres/postgres/blob/master/src/backend/postmaster/autovacuum.c#L2902), a table is slated for vacuum when `threshold = vac_base_thresh + vac_scale_factor * reltuples`.  With this knowledge, a simple query to determine tables requiring an autovacuum would be:

{% highlight sql %}
SELECT c.relname
  FROM pg_stat_all_tables t,
       pg_class c,
      (SELECT setting
         FROM pg_settings
        WHERE name = 'autovacuum_vacuum_threshold') AS avt,
      (SELECT setting
         FROM pg_settings
        WHERE name = 'autovacuum_vacuum_scale_factor') AS avsf
 WHERE c.oid = t.relid
   AND n_dead_tup > avt.setting::numeric + (avsf.setting::numeric * reltuples);
{% endhighlight %}

Enjoy!

# UPDATE 2020-09-02
Note that autovacuum will vacuum/analyze **all** relations in the list that it built up before napping again.  Therefore, if a table becomes eligible for autovacuum while autovacuum is processing a set of relations, that table will not be autovacuumed until the currently-running round of autovacuum finishes and wakes up after sleeping for `autovacuum_naptime`.
