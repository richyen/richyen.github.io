---
layout: post
title:  "The Curious Case of Split WAL Files"
date:   2019-01-09 12:00:00 -0800
tags: replication walsender walreceiver postgres PostgreSQL
comments: true
categories: replication postgres
---

# Introduction
I've come across this scenario maybe twice in the past eight years of using Streaming Replication in Postgres: replication on a standby refuses to proceed because a WAL file has already been removed from the primary server, so it executes Plan B by attempting to fetch the relevant WAL file using `restore_command` (assuming that archiving is set up and working properly), but upon replay of that fetched file, we hear another croak: "No such file or directory."  Huh?  The file is there?  `ls` shows that it is in the archive.  On and on it goes, never actually progressing in the replication effort.  What's up with that?  Here's a snippet from the log:

{% highlight text %}
2017-07-19 16:35:19 AEST [111282]: [96-1] user=,db=,client=  (0:00000)LOG:  restored log file "0000000A000000510000004D" from archive
scp: /archive/xlog//0000000A000000510000004E: No such file or directory
2017-07-19 16:35:20 AEST [114528]: [1-1] user=,db=,client=  (0:00000)LOG:  started streaming WAL from primary at 51/4D000000 on timeline 10
2017-07-19 16:35:20 AEST [114528]: [2-1] user=,db=,client=  (0:XX000)FATAL:  could not receive data from WAL stream: ERROR:  requested WAL segment 0000000A000000510000004D has already been removed

scp: /archive/xlog//0000000B.history: No such file or directory
scp: /archive/xlog//0000000A000000510000004E: No such file or directory
2017-07-19 16:35:20 AEST [114540]: [1-1] user=,db=,client=  (0:00000)LOG:  started streaming WAL from primary at 51/4D000000 on timeline 10
2017-07-19 16:35:20 AEST [114540]: [2-1] user=,db=,client=  (0:XX000)FATAL:  could not receive data from WAL stream: ERROR:  requested WAL segment 0000000A000000510000004D has already been removed

scp: /archive/xlog//0000000B.history: No such file or directory
scp: /archive/xlog//0000000A000000510000004E: No such file or directory
2017-07-19 16:35:25 AEST [114550]: [1-1] user=,db=,client=  (0:00000)LOG:  started streaming WAL from primary at 51/4D000000 on timeline 10
2017-07-19 16:35:25 AEST [114550]: [2-1] user=,db=,client=  (0:XX000)FATAL:  could not receive data from WAL stream: ERROR:  requested WAL segment 0000000A000000510000004D has already been removed
{% endhighlight %}

# What's going on?
I haven't personally been able to reproduce this exact scenario, but we've discovered that this happens when a WAL entry is split across two WAL files.  Because some WAL entries will span two files, Postgres Archive Replay doesn't internally know that it needs both files to successfully replay the event and continue with streaming replication.  In the example above, an additional detail would be to look at the `pg_controldata` output, which in this case looks something like this: `Minimum recovery ending location: 51/4DFFED10`.  So when starting up the standby server (after a maintenance shutdown or other similar scenario), it clearly needs file `0000000A000000510000004D` to proceed, so it attempts to fetch its contents from the archive and replay it.  It happily restores all the relevant WAL files until it reaches the end of the `51/4D` file, at which point it can no longer find more WAL files to replay.  The toggling mechanism kicks in, and it starts up the `walsender` and `walreceiver` processes to perform streaming replication.

When `walreceiver` starts up, it inspects the landscape and sees that it needs to start at `51/4DFFED10` for streaming replay, so it asks walsender to fetch the contents of `0000000A000000510000004D` and send it.  However, it's been a long time (maybe lots of traffic or maybe a `wal_keep_segments` misconfiguration) and that `0000000A000000510000004D` file's gone.  Neither the walsender or the walreceive know that LSN `51/4DFFED10` doesn't actually exist in `0000000A000000510000004D`, but it's actually in `0000000A000000510000004E`, and `0000000A000000510000004D` is already gone, so it wouldn't be able to scan it and find out that `0000000A000000510000004E` is needed.  

# A possible solution
In one of the cases I worked on, the newer file (`0000000A000000510000004E` in the above example) had not been filled up yet.  It turned out that it was a low-traffic development environment, and the customer had simply needed to issue a `pg_switch_xlog()` against the primary server.

Of course, this isn't a very reliable solution, since it requires human intervention.  In the end, the more reliable solution was to use a replication slot, so that Postgres always holds on to the necessary WAL files and doesn't move/delete them prematurely.  While [streaming replication slots have their pitfalls](http://richyen.com/replication/postgres/2019/01/08/zombie_transactions.html), when used properly they will ensure reliable replication with minimal configuration tweaks.
