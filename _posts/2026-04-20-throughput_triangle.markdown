---
layout: post
title: "The Postgres Performance Triangle"
date:   2026-04-20 00:00:00 -0800
tags: PostgreSQL postgres performance
comments: true
categories: postgres
---

Everyone who's gone at least knee-deep in  photography knows there’s this idea of the *exposure triangle*: aperture, shutter speed, and ISO. Depending on what you're going for artistically, you adjust the three parameters, knowing that there are trade-offs in doing so.  After working on a few cases, and presenting solutions to customers, I’ve started to think about Postgres performance tuning in a similar way -- there are basic parameters that can be tuned, and there are trade-offs for the choices DBAs make:

- Memory Allocation
- Disk I/O
- Concurrency

Each of these (in broad strokes) affects throughput -- how much work your system gets done.

Caveat: I know that in the academic sense, "throughput" doesn't quite capture the balance of these concepts, but please bear with me!

Let's talk about how each of these three work together with the whole system, and what the trade-offs look like.

---

## Memory Allocation

When you increase memory allocation in Postgres, whether it’s `shared_buffers` or `work_mem`, things tend to feel smoother.  Most notably, queries spill to disk less often, sorts and joins stay in memory, cache hit rates improve.  But there’s a trade-off that’s easy to miss at first, especially with these two parameters.  A single complex query can consume multiple chunks of `work_mem` (see [Laetitia's excellent post about it](https://mydbanotebook.org/posts/work_mem-its-a-trap/)). Multiply that across concurrent queries, and you begin to see the OS consuming swap space, churning at checkpoints, and even OOM Killer getting invoked.  So while more memory *can* make things faster, it also quietly reduces how much concurrency your system can safely handle.

I'd relate this to aperture -- you can throw money at some fast glass, but you also get shallower depth of field (in an annoying way).

---

## Disk I/O

Disk is where things go when memory isn’t enough, or when an access pattern requires it.  We see examples of this in , sequential scans, random index lookups, and temporary files from sorts or hashes.  Lowering `work_mem` might increase disk I/O due to sorts spilling to temp files, for example.  We can try to minimize disk I/O by adding indexes, increasing `work_mem`, or simply rewriting queries.

Another way we can try to affect disk I/O is to tinker with the costs, to encourage the query planner to choose one scan method over the other.  In any case, our attempts to balance disk I/O and memory usage can be pretty straightforward at first, but could become complicated at scale.  That's where partitioning and read-only replicas come in, but I'm beginning to digress...

Indexes, in particular, are where things start to get interesting.  Adding an index can feel like an easy win, as it leads to fewer rows scanned and less CPU work per query, along with less disk activity, but there are trade-offs:

- Every `INSERT` will update every relevant index  
- Every `UPDATE` can potentially rewrite index entries  
- Every `DELETE` leaves behind cleanup work (vacuum)

At scale, we also see other effects:

- Indexes get large  
- Cache hit rates drop (because there’s more to cache)  
- Random I/O increases  

So an index that helps one query might quietly make others worse, or make writes more expensive.

It’s like raising ISO to compensate for low light. You get the shot, but the noise shows up somewhere else.

---

## Concurrency

So far, this has all been somewhat per-query. But things change when you introduce concurrency.  In a high-demand service, the instinct is to increase `max_connections` to allow the service to scale up, but in my experience there's a price to pay for this kind of concurrency.  Some people fail to notice that each connection brings its own memory usage, takes up a spot in Postgres' internal data structures, and puts the system at risk for increased CPU demand and resource contention.

In the photography analogy, you can turn down the ISO very low on a bright and sunny day, but that won't be enough.  Soon, you'll be closing the aperture and increasing the shutter speed, and then you lose your ability to create the artistic feel that you're actually trying to go for.  So what do photographers do?  They use an ND filter to limit how much light hits the sensor.

In Postgres, that “ND filter” is something like a connection pooler, like [PgBouncer](https://www.pgbouncer.org/).  Instead of letting thousands of connections compete for CPU: You cap active queries, you allocate more resources to each actual DB session, and you trade a bit of latency for stability.  Sometimes, to keep your throughput, you need some additional accessories.

---

## The Art of Postgres

As a DBA, you can calculate optimal index usage, memory sizing, and expected I/O patterns, but those calculations tend to assume a steady state.  Every DBA knows that real production systems are always changing, due to traffic patterns, scaling, and new features getting rolled out on the application side.  As the organization changes, the work to keep the database performant is dependent upon the DBA being both a Database Administrator as well as a Database Artist, working with internal teams to know which indexes to add/drop, how much concurrency to allow, and how to allocate memory without running out of it.


Instead of asking, "What’s the optimal configuration?" it might be more useful to ask these questions:

- Where is my system currently paying the cost—memory, disk, or CPU?  
- If I relieve pressure here, where does it move?  
- How much can we tolerate that new pressure?

Costs don’t disappear -- it just shifts -- and it's the DBA's job to help decision-makers decide where to shift it to.

---

## Conclusion

There's more to photography than exposure -- there's composition, color-correction, external lighting, and so much more.  In the same way, this discussion has just been one part of database administration.  There's so much more to go over, in terms of creating a robust and scalable database.  I wanted to highlight this topic because I do find that some users tend to approach database architecture without considering all the trade-offs.  We can definitely get the database to peform well, but there's no one-size-fits-all solution for every situation.  It takes thought, planning, testing, and discussion with stakeholders to come up with a good solution.
