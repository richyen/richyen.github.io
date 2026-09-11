---
layout: post
title:  "Looking Forward to PG Summit 2026"
date:   2026-09-14 00:00:00 -0800
tags: PostgreSQL postgres benchmarking performance hardware
comments: true
categories: postgres
---

On October 1, I'll be speaking at [PG Summit 2026](https://postgresql.us/events/postgressummitus2026/schedule/session/2375-pushing-postgresql-to-the-limit-how-to-benchmark-hardware-with-postgres/) about benchmarking hardware with Postgres.  I'm looking forward to sharing some tips and learnings that I've picked up over the years.  In anticipation of the presentation, I just wanted to share a little bit about some of my motivations for the topic.

## Testing Components v. Testing Postgres

If you want to know how fast a disk is, use `fio`.  If you want to know how quickly a CPU can perform a particular operation, there are better tools for that too.  Those tests can tell you something useful about an individual component, and the numbers on the product page might even be meaningful in that context.

But a Postgres benchmark is not really trying to reproduce the number in the marketing material (A Samsung EVO Plus 990 is marketed at read/write speeds up to 7,150/6,300MB/s, but I don't think we'll hit that on a legit Postgres cluster).  It's important to remember that Postgres is a complicated system with memory, concurrency, caching, WAL, checkpoints, background workers, and several kinds of maintenance that can all happen at once.  A benchmark that runs for ten seconds might measure a very fast and very warm slice of that system while missing the things that make production interesting.

An experienced DBA or DBRE knows that autovacuum creates work while the workload is running, and checkpoints can create bursts of I/O.  A high-concurrency workload can run into lock contention or connection limits before the storage device itself is particularly busy.  Even cache state changes the question: are we measuring a workload that fits comfortably in memory, or one that has to keep reading from storage?  This is why it is difficult to use Postgres to make a clean statement about a piece of hardware.  There are too many other things involved, and they are not noise to be discarded.  They are part of the database we are trying to operate.

## We Need to Ask the Right Questions When Thinking About Databases

The useful question is not, "How fast is this SSD?"  It is something closer to, "Can this workload run acceptably on this system, and how much more of it can the system handle?"

Defining the workload is an important first step in benchmarking.  Is it an OLTP workload with lots of small concurrent transactions?  Or is it an analytical workload with large scans and joins?  A workload with wide JSON documents, compressible values, or unusually high write volume?  Once we identify our workload, we can tune parameters and monitor different factors in controlled steps and watch what happens.  When throughput stops scaling, latency violates the objective, or some resource becomes saturated, we get a better understanding of what the database as a whole is capable of.

The first bottleneck also tells us what to do next.  Maybe we need to tune the configuration.  Maybe the workload needs a different design.  Maybe we need to rearrange the infrastructure or choose different hardware.  The benchmark should help us understand those decisions.

## More Than a Peak Number

A credible benchmark needs to run long enough to include a few autovacuum and checkpoint cycles, and it needs to be repeatable.  We should record the configuration, dataset, client placement, ramp-up period, measurement window, and acceptance criteria.  We should also test what happens after the system is overloaded: does it recover, or does it remain stuck in a degraded state?

So strict hardware benchmarking still has a place, and it should be done separately.  `fio` is the right tool when the question is storage performance.  A Postgres benchmark has a different aim: understanding whether a particular database workload can run on a particular system, where it stops scaling, and what constraint we meet first.

I'll dig into that process at PG Summit 2026, including HammerDB, `pgbench`, workload design, and the evidence that helps us identify the real bottleneck.  I hope to see you there!