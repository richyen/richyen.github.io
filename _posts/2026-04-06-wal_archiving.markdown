---
layout: post
title: "WAL as a Data Distribution Layer"
date:   2026-04-06 00:00:00 -0800
tags: PostgreSQL postgres replication archiving log_shipping
comments: true
categories: postgres
---

# Introduction

Every so often, I talk to someone working in data analytics who wants access to production data, or at least a snapshot of it.  Sometimes, they tell me about their ETL setup, which takes hours to refresh and can be brittle, with a lot of monitoring around it.  For them, it works, but it sometimes gets me wondering if they need all that plumbing to get a snapshot of their live dataset.  Back at Turnitin, I set up a way to get people access to production data without having to snapshot nightly, and I thought maybe I should share it with people here.

# Common Implementations and Their Risks

Typical solutions that we might encounter as we give people a little bit of access to production data:

### 1. Query the primary

This is generally a bad idea, since you don't want users getting access to the production prirmary, lest they make some mistakes or do something to lock up tables that prevent customers from using your apps.  Even with a read-only user, large data analytics queries could cause unwanted interference that negatively affect your uptime.  This is almost certainly not the way to go.

### 2. Query a streaming replica

This is better, but doing this is not free.  Long-running queries can create replay lag, vacuum conflicts can cancel queries, and I/O contention can affect the primary upstream.  It's safer since users are forced to be read-only, but that still carries risk.

### 3. Nightly snapshots / rebuilds

Having time-based snapshots and rebuilds are the most common form of getting data out to analysts.  ETL queries run at night (or some other specified regular interval) and provide the information needed to do the necessary work.  This works, but is another piece of software that produces somewhat stale data, depending on how much stale-ness can be tolerated.

# Once Upon a Time, Before Streaming Replication

If you’ve spent any time in Postgres, you already understand streaming replication.  Primary sends WAL to standby, and standby replays the WAL stream.  All the tutorials talk about using `pg_basebackup`, setting `hot_standby` and `standby.signal` and configuring `primary_conninfo`.


However, many people don't know that before streaming replication, there was log shipping.  Introduced in v. 8.2, it was the predecessor to what eventually became hot standby/streaming replication in v. 9.0.  Instead of maintaining a live connection between primary and standby, the two clusters are decoupled.  WAL files are shipped (via `scp` or `rsync` or some other mechanism -- maybe even NFS) to the replica, and then replayed there.

# Log Shipping Hits a Different Point on the Tradeoff Curve

With WAL log shipping the standby never connects to the primary, and the primary never tracks the standby, and therefore there is no backpressure mechanism (i.e. no cancelled queries because of conflict with recovery, no need for `hot_standby_feedback`).

While you may not get up-to-the-millisecond minimized replication lag, you get pretty close to real-time data.  In some cases, this lag may even be desirable -- you could throttle the playback so you are an hour behind, even giving yourself some time to look at a table's state before someone fat-fingers an `UPDATE` without a `WHERE` clause.

# A Subtle but Important Detail

Postgres doesn’t force you to choose one mechanism over the other.  A standby can use both `primary_conninfo` AND `restore_command`.  The way it works is that it will toggle between the two, depending on availability.  If the primary is disconnected for some reason, it will switch over to `restore_command` until it cannot find the WAL file it wants, and then it flips back to `primary_conninfo` again.

Log shipping isn’t just a legacy mode, but it’s part of the replication continuum.  It's like incremental backup, except that your backup is always full-loaded and can be queried against.  For these reasons, keeping your WAL files around is a very good practice.

# Architecture Pattern: Introduce a WAL Hub

Instead of thinking in terms or replication happening between a primary and a number of standbys, it may be useful to think about a cenral WAL archive host, even if it's an S3 bucket, so that many consumers can access data at any point in time.

These consumers can be analytics standbys, QA environments, or ad-hoc data sandboxes -- or whatever else you want to give a copy of near-realtime production data to, without risking replication backpressure or compromising network security.

# A Hands-On Approach

I created a [simple demo](https://github.com/richyen/toolbox/tree/master/demos/wal_shipping) that sets this up end-to-end.  It sets up 3 containers in Docker -- a primary, standby, and a mock WAL archive location.  _Disclaimer:_ yes, I used AI to help me generate the scripts, but it's exactly how I had it set up at Turnitin (yes, we used `rsyncd` back in 2009 -- there might be better stuff out there these days).

Some key configuration params for clarity:
- `archive_command` pushes WAL files to a directory
- `restore_command` pulls WAL files on the standby
- `standby.signal` enables continuous recovery
- `hot_standby=on` allows read-only queries
- `archive_mode=on` not entirely necessary, but for posterity

Note that in this example, some characteristics of the standby:
- No `primary_conninfo`
- No replication slots used
- No entries in `pg_stat_replication` show up on the primary.

If you want, you can set up traditional streaming replication in parallel to this log shipping standby -- it doesn't interfere with the log shipping so long as WAL files get to the archive location.

# Why This Pattern Deserves More Attention

Most teams default to streaming replication because it’s the most visible feature.

But Postgres replication isn’t one thing; it’s a set of primitives:

- WAL generation
- WAL transport
- WAL replay

Streaming replication couples all three and log shipping lets you separate them.  And once you do that, new architectures open up!
