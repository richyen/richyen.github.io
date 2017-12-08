---
layout: post
title:  "Be sure to stop your backups!"
date:   2017-12-07 22:51:00 -0800
tags: PostgreSQL postgres Streaming Replication
comments: true
categories: postgres
---

**tl;dr:** This article is about using `pg_stop_backup()` when setting up Streaming Replication.  It is not an article about backup/restore methodology or policy

# Introduction
In a recent support case, I came across a customer who used a clever way to create streaming replication base backups--by taking a Google Cloud instance and cloning it.  With the proliferation of cloud computing, it's very convenient to be able to create a block-level clone of a VM within minutes or even seconds, and it would be much faster than any program like scp or rsync.  They had found it to be faster than `pg_basebackup` for sure, on the order of several minutes for a ~50GB database.  Basically, they would start a base backup, clone the VM, and then stand up the clone as a streaming replication standby.  Unfortunately, for some reason, they could not use `psql` to log in to the standby--they would simply see the following error:

{% highlight text %}
FATAL: the database is starting up
{% endhighlight %}

It was really strange.  If you go to the primary and do a `SELECT * FROM pg_stat_replication`, you'll see that while WAL is advancing on the primary, it's getting replayed on the standby--the data stream is flowing, and replication is working, but yet we're not able to log in to the standby to run read-only queries.

### What's going on?
A clue into this is that in a typical streaming replication instance, you'll see the following in your log on startup:

{% highlight text %}
LOG: entering standby mode
LOG: redo starts at 13/B0000028
LOG: invalid record length at 13/B0000108
LOG: started streaming WAL from primary at 13/B0000000 on timeline 1
LOG: consistent recovery state reached at 13/B00235B8
LOG: database system is ready to accept read only connections
{% endhighlight %}

On this customer's instance, we weren't seeing the last two lines (`consistent recovery state reached...` and `database system is ready to accept read only connections`).  Apparently, the standby wasn't in a consistent state with the primary.

### But, it LOOKS consistent...

One may argue that if you look in `pg_stat_replication`, all the evidence points to the idea that the standby IS in a consistent state with the primary.  It's replaying all the primary's WAL.  The LSN is advancing on both the standby and the primary--how could it NOT be consistent?  To the human eye and the human intuition, things are consistent, as evidenced by the advancing LSN, but to a machine, it may not know that.  Recall that if not using `pg_basebackup`, the proper steps to setting up a Streaming Replication standby involves the following steps:


1. Execute `pg_start_backup('any_label')` on the primary
1. Copy all the files in the primary's `$PGDATA` directory, including WAL files
1. Execute `pg_stop_backup()` on the primary
1. Set up `recovery.conf` on the standby (and delete postmaster.pid, set hot_standby=on, etc.)
1. Start up Postgres on the standby

Apparently, the customer had neglected to execute the `pg_stop_backup()` step, which left the standby in a state of technically perpetual inconsistency.  This is because the `pg_stop_backup()` step writes a `BACKUP_END` entry into the WAL stream, which lets the standby know that it is done replaying all the copied WAL from step 2, and has now technically reached a consistent state, and can allow read-only connections.  Without this `BACKUP_END` entry, it will never know whether it has replayed all the WAL during the copy (what if the copy took a whole year to process?).  This `BACKUP_END` entry is the foolproof way for Postgres to ensure a consistent state between the primary and standby.

### Conclusion
The moral of the story: **Be sure to stop your backups!**  When setting up a streaming replication standby, it is imperative to execute `SELECT pg_stop_backup()` after copying all of `$PGDATA`; without it, you'll never be able to log in to your standby and run your read-only queries.
