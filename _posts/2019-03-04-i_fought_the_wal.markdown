---
layout: post
title:  "I Fought the WAL, and the WAL Won: Why hot_standby_feedback can be Misleading"
date:   2019-03-04 16:15:00 -0800
tags: replication wal hot_standby_feedback postgres PostgreSQL
comments: true
categories: replication postgres hot_standby_feedback
---

# Introduction
When I first got involved in managing a Postgres database, I was quickly introduced to the need for replication.  My first project was to get our databases up on Slony, which was the hot new replication technology, replacing our clunky DRBD setup and allowing near-realtime read-only copies of the database.  Of course, with time and scale, Slony had a hard time keeping up with the write traffic, especially since it ultimately suffered from write amplification (each write ultimately becomes two or more writes to the database, because of all the under-the-hood work involved).  When Postgres Streaming Replication came out in v. 9.0, everyone felt like they struck gold.  Streaming Replication was fast, and it took advantage of an already-existing feature in Postgres: the WAL Stream.

Many years have passed since v. 9.0 (we're coming up on v. 12 very soon).  More features have been added, like Hot Standby, Logical Replication, and some two-way Master-Master replication extensions have been created.  This has been quite a path of growth, especially since I remember someone saying that Postgres' roadmap would not include replication at a BOF at PGCon, circa 2010.

With all the improvements to Streaming Replication over the years, I think one of the most misunderstood features is `hot_standby_feedback`, and I hope to clarify that here.

With Streaming Replication, users are able to stand up any number of standby servers with clones of the primary, and they are free to throw all sorts of load at them.  Some will send read-only traffic for their OLTP apps, huge cronjobs, and long-running reporting queries, all without affecting write traffic on the primary.  However, some will occasionally see that their queries get aborted for some reason, and in their logs they might see something like:

{% highlight text %}
ERROR:  canceling statement due to conflict with recovery
{% endhighlight %}

That's an unfortunate reality that nobody likes.  Nobody wants their queries canceled on them, just like nobody likes to order a pastrami sandwich, only to be told 10 minutes later that the sandwich shop has run out of pastrami.  But it happens.  Here, something is causing a [query conflict](https://www.postgresql.org/docs/current/hot-standby.html#HOT-STANDBY-CONFLICT), and that usually happens when some data in the WAL stream needs to get replayed, most frequently some old data removal, whether it's a `DELETE`, or a `DROP TABLE`, or even some `VACUUM` activity removing dead rows.  Doing some Googling on Postgres replication, users may come across the suggestion that turning on `hot_standby_feedback` will solve their query-cancellation problems.  Many people happily set `hot_standby_feedback = on` and things start working again, but some customers I've come across were met with disappointment when they continued to see `ERROR:  canceling statement due to conflict with recovery` in their logs.

# Why do query cancellations still happen?
The important thing to remember about Postgres' Streaming Replication is that its goal is to create a copy of the database, to get the WAL stream to the other side.  Now, DBAs might have a different goal, which include providing a way for queries and reporting to be run on the clone, but that's not Postgres' goal.  The DBA has the power to configure some `GUC`s to tell Postgres not to be so aggressive in some aspects so that there can be some headroom in running queries on the standby.
If the WAL stream doesn't get processed on the standby, WAL files will pile up and bloat the `pg_xlog`/`pg_wal` folder, putting the primary at risk of running out of disk space.

# What exactly does `hot_standby_feedback` do?
I won't get into the technical details here, as I think [Alexey Lesovsky did a pretty good job explaining it](https://blog.dataegret.com/2015/09/postgresql-hot-standby-feedback-how-it.html), and there's always the [source code](https://github.com/postgres/postgres) for the adventurous.  In short, it sends info back to the primary (in the form of a `pg_stat_replication.backend_xmin` value) to help it decide which dead tuples are safe to be `VACUUM`ed.  In other words, while a standby is taking queries and giving visibility to a particular `backend_xmin` value, the primary should not vacuum up those related tuples yet:

{% highlight text %}
-bash-4.1$ psql -p5432 -c "SELECT application_name, backend_start, backend_xmin, state, sent_location, write_location, flush_location, replay_location FROM pg_stat_replication"
 application_name |          backend_start          |     backend_xmin      |   state   | sent_location | write_location | flush_location | replay_location
------------------+---------------------------------+-----------------------+-----------+---------------+----------------+----------------+-----------------
 walreceiver      | 01-MAR-19 23:18:55.31685 +00:00 |{look ma, nothing here}| streaming | 0/6000060     | 0/6000060      | 0/6000060      | 0/6000060
(1 row)
-bash-4.1$ psql -p5433 -c "ALTER SYSTEM SET hot_standby_feedback TO on"
ALTER SYSTEM
-bash-4.1$ pg_ctl -D /var/lib/pgsql/9.6/standby_pgdata restart
waiting for server to shut down.... done
server stopped
server starting
-bash-4.1$ psql -p5432 -c "SELECT application_name, backend_start, backend_xmin, state, sent_location, write_location, flush_location, replay_location FROM pg_stat_replication"
 application_name |          backend_start           |     backend_xmin      |   state   | sent_location | write_location | flush_location | replay_location
------------------+----------------------------------+-----------------------+-----------+---------------+----------------+----------------+-----------------
 walreceiver      | 01-MAR-19 23:21:18.373624 +00:00 | {hs_feedback on} 2346 | streaming | 0/6000060     | 0/6000060      | 0/6000060      | 0/6000060
(1 row)
{% endhighlight %}

Basically, it's a delay tactic, keeping cleanup information out of WAL because once the dead tuples are `VACUUM`ed up, that information is going to get written into the WAL stream and crete a conflict on the standby side.  Notice that there's a tradeoff here: setting `hot_standby_feedback=on` can incur some table bloat on the primary, but often it's not significant.  However, there are some cases of query cancellation that `hot_standby_feedback` cannot prevent:

* Exclusive locks on relations on the primary
* Flaky `walreceiver` connections
* Frequent writes on a small number of tables

## Conflicts arising from exclusive locks
If Streaming Replication is going to be a reliable technology, all standbys need to be consistent with their primary (master) database.  This means that the changes being made on the primary need to be replayed on the standby(s) as soon as possible, especially if those changes are DDL, or changes made with exclusive locks.  Any delay would result in an inconsistent database (who wants to look at a table when it's already been dropped?), and should the primary go down and necessitate a failover, it would be most desirable that the standby(s) be fully in sync with its primary.  For this reason, DBAs would want the WAL stream replayed as quickly as possible.

Consistency also means that when Alice and Bob are running queries on the read-only standby, they should get results that are accurate, as if they had run their queries on the primary (unless, of course, the DBA has set up the standby to be trailing the primary by a fixed amount of time, like setting `recovery_min_apply_delay` in `recovery.conf`).  However, if one person is hogging up the database with a long-running query that prevents WAL from being replayed, something's gotta give--and that's where queries can get canceled.  DBAs might try to tweak things like `max_standby_archive_delay` or `max_standby_streaming_delay` to give conflicting queries some time before canceling them.  These should be set carefully, considering how much replication delay the business allows.

## Effect of flaky `walreceiver` connections
Network hiccups that disrupt the `walreceiver` connections ultimately invalidate the `backend_xmin` that is getting sent back to the primary.  Basically, if the `walreceiver` connection is broken, the primary is free to vacuum whatever it wants until `walreceiver` reconnects and tells the primary what the new `backend_xmin` should be.  Some undesired vacuums (from the standby user's perspective) may occur in the interim, before `walreceiver` reconnects, thereby setting up the user for potential query cancellation.  This can be mitigated using [replication slots](https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS), which keeps track of `xmin` across `walreceiver` disconnects.

## Frequent writes on a small number of tables
`VACUUM` activity is usually not blocking, but if there's enough insert/delete traffic, a vacuum job might discover that an entire data page is flagged as deleted, at which point it will attempt to take an `EXCLUSIVE LOCK` on the relation to remove the data page from disk, thereby shrinking the table.  This locking behavior is basically the same as DDL (from a streaming replay standpoint), and subjects in-flight queries to possible cancellation.

# Conclusion
There are a handful of other ways query cancellations can arise, even with `hot_standby_feedback=on`, but they are more rare.  Taking a peek at `pg_stat_database_conflicts` will help with understanding the cause of the canceled queries, and therefore aid in implementing the correct mitigating path.  Ultimately, `hot_standby_feedback` is just one of many ways to deal with query cancellations on a standby, and users should understand that such cancellations are necessasry at times in order to maintain a consistent and reliable clone.  Any attempts to give higher priority to standby-side queries, whether it's through `hot_standby_feedback` or any other means, comes at the cost of slowing down replication (albeit sometimes miniscule) between primary and standby.

*Special thanks to Andres Freund for assistance and review*
