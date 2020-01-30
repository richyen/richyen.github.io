---
layout: post
title:  "The Most-Neglected Postgres Feature"
date:   2020-01-29 13:00:09 -0800
tags: PostgreSQL postgres logging monitoring
comments: true
categories: postgres
---

# Introduction
I recently did some work with a customer who had some strange behavior happening in his database.  When I asked for his logs, I found that each line had a message, and just one timestamp prefixed to it.  In other words, he had `log_line_prefix = '%t '`.  This made it hard for me to figure out who did what, especially as his database was serving many clients and applications.  It got me thinking, and I scoured through our other clients' `postgresql.conf` files that had been shared with me over the years, and in ~140 conf files, I found the following:

* 5% of users don’t change `log_line_prefix`
* 7% of users don’t log a timestamp (but they might be using syslog, which would include its own timestamp)
* 38% only log a timestamp (and nothing else)
* The average number of parameters included in `log_line_prefix` is `0.93`

# A bit of history
Wait a minute.  On average less than one parameter in `log_line_prefix` for any `postgresql.conf`?  How could that be?  Bear in mind that prior to v. 10, the default for `log_line_prefix` was simply `''`.  That's right--nothing.  It was up to the DBA to set a value.  Seeing that this wasn't very useful, [Christoph Berg submitted a patch](https://github.com/postgres/postgres/commit/7d3235ba42f8d5fc70c58e242702cc5e2e3549a6) to set the default to `'%m [%p] '`.  While it's not the best setting, it's a significant improvement to nothing at all.  What this *does* tell me though, is that many users out there using v. 9.x have not bothered to change `log_line_prefix` at all, making this one of the most neglected important features PostgreSQL has to offer.

_EDIT_: Some of these conf files were from EDB Postgres Advanced Server (EPAS) deployments.  EPAS has been shipping with `log_line_prefix = '%t '` by default since 2012, so those 38% of users who log only a timestamp are users who don't change `log_line_prefix`, possibly making the statistic more like "43% of users don't bother to change `log_line_prefix`."

# More important than some may think
Adequate logging opens up the door to many possibilities.  With `log_connections` and `log_disconnections`, you can see when a session began and ended.  With `log_min_duration_statement` (along with `auto_explain`), you can identify any poorly-running queries.  With `log_autovacuum_min_duration`, you can see what an autovacuum job did, how much space it freed up, and perhaps tip you off to any stray/idle transactions preventing you from vacuuming more.  Same goes with `log_temp_files`, which can tip you off to any `work_mem` adjustments you may need.  However, in order of any of this to be possible, `log_line_prefix` needs to be adequately set.

`log_line_prefix` can log many important facets of a session or query.  There are 17 parameters that can be logged and while not all of them need to be included in your `postgresql.conf`, here are some of my favorites:

* `%a` - _Application Name_ - Allows quick reference and filtering
* `%u` - _User Name_ - Allows filter by user name
* `%d` - _Database Name_ - Allows filter by database name
* `%r` - _Remote Host IP/Name_ - Helps identify suspicious activity from a host
* `%p` - _Process ID_ - Helps identify specific problematic sessions
* `%l` - _Session/Process Log Line_ - Helps identify what a session has done
* `%v`/`%x` - _Transaction IDs_ - Helps identify what queries a transaction ran

These, along with a timestamp (`%m`) make it possible for a DBA or developer to quickly filter on specific paramters to identify issues and collect historical data.  Moreover, log analytics tools like [`pgbadger`](https://github.com/darold/pgbadger) work best with a more comprehensive `log_line_prefix`, so something like `log_line_prefix = '%m [%p:%l] (%v): host=%r,db=%d,user=%u,app=%a,client=%h '` is what I like to use.  With this, I can do the following:

* `grep` on `[<pid>]` to find lines pertaining to a specific active backend to see what it's done so far (cross referencing with `SELECT * FROM pg_stat_acitivity`)
* `grep` on a PID to see what it did before the database crashed
* Filter out apps with a specific application name (like `autovacuum` -- because I know for a fact that `autovacuum` didn't cause the problem I'm _currently_ trying to investigate)
* Filter out a specific database name because in my multi-tenant setup, I don't need to worry about that database
* Focus on a specific transaction ID to help my developer know at which step in his code a query is failing

Without setting `log_line_prefix`, all you have is a bunch of timestamps and a bunch of queries or error messages, not knowing how it relates with the set of users and applications that might be accessing the database.  Setting `log_line_prefix` will lead to quicker diagnosis, faster incident resolution, happier users, and rested DBAs.

# That's not all!
While setting `log_line_prefix` is very important, from experience I also think the following are important for DBAs to maintain their sanity:

* `log_min_duration_statement` -- helpful in identifying slow queries
* `log_statement` -- good for auditing purposes
* `log_[dis]connections` -- good for auditing purposes
* `log_rotation_age`/`log_rotation_size` -- good for organization, and for keeping your logfiles small(ish)
* `log_autovacuum_min_duration` -- gives insight into autovacuum behavior
* `log_checkpoints` -- know what queries happened between checkpoints
* `log_temp_files` -- helps identify work_mem shortages, I/O spikes
* `auto_explain` -- not a parameter, but a useful extension

These parameters will help with diagnosis and in some cases, when coupled with `pgbadger` or [`pganalyze`](https://pganalyze.com/), can assist with capacity planning.

# How much is too much?
Some may complain that logging too many things will lead to I/O overhead and actually increase time for diagnosis.  DBAs don't want to be drinking from a firehose at 3AM!  While this may be true, some steps can be taken to mitigate these effects:

* Rotate your logfiles every hour (or more frequently on super-busy systems)
* Compress your logfiles after they've been rotated
* Put your `log_directory` on a separate partition

Getting familiar with commandline tools like `grep`, `sed`, and `awk` are also very important, so that you can quickly filter and zoom in on the suspected users, transactions, and processes.

# Conclusion
While a company's bottom line is often correlated with efficiency, performance, and throughput, there's no excuse for inadequate logging. Good logging saves valuable time, and time is money.  PostgreSQL's logging is very powerful and informative, even without third-party log processing tools like Datadog and Splunk.  It's the first and most powerful resource (along with looking at `pg_stat_acitivity`) that DBAs have when it comes to figuring out what caused problems in your application stack, and the tell-all snitch when it comes to investigating a database crash.  Don't neglect it!
