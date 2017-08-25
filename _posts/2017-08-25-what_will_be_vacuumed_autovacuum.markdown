---
layout: post
title:  "What tables will be vacuumed at the next autovacuum cycle?"
date:   2017-08-25 13:01:09 -0800
tags: autovacuum vacuum maintenance PostgreSQL postgres
categories: postgres
---

# Introduction
Someone recently asked me if there was a way to tell which table(s) are slated for `VACUUM` at the next autovacuum cycle.  I couldn't find any results after a short search on Google, so I decided to come up with my own query.  [According to source](https://github.com/postgres/postgres/blob/master/src/backend/postmaster/autovacuum.c#L2902), a table is slated for vacuum when `threshold = vac_base_thresh + vac_scale_factor * reltuples`.  With this knowledge, a simple query to determine tables requiring an autovacuum would be:

{% highlight sql %}
SELECT relname
FROM pg_stat_all_tables t,
    (SELECT setting
     FROM pg_settings
     WHERE name = 'autovacuum_vacuum_threshold') AS avt,
    (SELECT setting
     FROM pg_settings
     WHERE name = 'autovacuum_vacuum_scale_factor') AS avsf
WHERE n_dead_tup > avt.setting::numeric + (avsf.setting::numeric * reltuples);
{% endhighlight %}

Enjoy!
