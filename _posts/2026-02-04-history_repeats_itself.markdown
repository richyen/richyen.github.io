---
layout: post
title:  "History Repeats Itself"
date:   2026-02-04 11:00:00 -0600
tags: PostgreSQL openai pgbouncer replication load_balancing haproxy
comments: true
categories: postgres
---

# Over 15 years later, some solutions are still great solutions

## Introduction
OpenAI recently [shared their story about how they scaled to 800 million users](https://openai.com/index/scaling-postgresql/) on their ChatGPT platform.  With the boom of AI in the past year, they've certainly had to deal with some significant scaling challenges, and I was curious how they'd approach it.  To sum it up, they addressed the following issues with the following solutions:

- Reducing load on the primary (offloaded read-only queries to replicas)
- Query optimization (query tuning and configuring timeouts like `idle_in_transaction_session_timeout`)
- Single point of failure mitigation (configured hot-standby for high-availability)
- Workload isolation (implemented a software solution for load-balancing)
- Connection pooling (deployed [pgBouncer](https://www.pgbouncer.org/))
- Cache misses (implemented a cache locking mechanism)
- Scaling read replicas (implemented cascading replication)
- Resource exhaustion (implemented rate-limiting, tuned ORM)
- Full table rewrites on schema changes (enforced strict DML policies)

Indeed, there was a lot of work put in to scale to "millions of queries per second (QPS)" and I applaud their team for implementing these solutions to handle the unique challenges that they faced. 👏👏👏

## Taking a Walk Down Memory Lane
While reading through their post, I couldn't help but think to myself, _wow, some of the solutions they used are not much different from ours 15 years ago!_  Fifteen years ago, I was the head DBA at [Turnitin](https://turnitin.com) (called iParadigms at the time).  Times were different back then, before the massive boom of social media (Instagram wasn't a thing at the time!), and we were all on-prem, switching from spindle-based disk to SSDs.  At that time, we were likewise facing challenges scaling to 3000 QPS to serve up data to students and teachers across the US, Canada, and the UK.  Our founders were making a lot of headway in promoting Turnitin to secondary schools and universities, and we were regularly facing the struggle of having "just enough" resources to keep our systems running smoothly.

## Some Things Don't [Need to] Change
To address the challenges that we faced 15 years ago, we employed similar solutions that the OpenAI team devised in 2025, namely:

### Reducing load on the primary
To reduce load on the primary, we also implemented a software-based solution to send read-only queries to our replicas.  Written in Perl, our Multiplexor listened to all incoming database traffic (port 5432) and directed transactions with DML queries to the primary, while sending other queries to the standbys.  This ensured that the primary only received write traffic (though some read traffic was necessary) and kept I/O as low as we could manage.

### Connection pooling
To ensure that each database session gets maximum resources for sort, join, and aggregation operations, OpenAI selected pgBouncer as the connection pooler of choice, and the used Kubernetes as a load-balancing mechanism.  This is clever (we didn't have Kubernetes at the time, but I think I might implement it if I find myself in a DBA role again).  pgBouncer is a solid choice for connection pooling; with its high configurability and server session management, [DBAs get great benefit in keeping operational overhead low and resource availability high](https://richyen.com/postgres/2019/06/25/pools_arent_just_for_cars.html).

### Workload isolation
To isolate high-tier and low-tier workloads, OpenAI implemented a software solution.  They didn't specifically call this out, but I suppose this is in conjunction to their Kubernetes load-balancing configuration.  At the time, we also wanted to ensure that load was balanced across our four replicas, and that no one of them would take the brunt of read traffic.  To implement this at the time, we used `haproxy` and configured it to run some health-checking Bash scripts to determine where to route traffic.  Fifteen years later, `haproxy` might not be a buzzword, but solid scripting and software engineering keep the lights on!

### Scaling read replicas
The OpenAI team detailed how they employed cascading replication as the mechanism to scale out to "nearly 50 read replicas" to handle their millions of QPS.  I suspect that in addition to adding tremendous load on the databases, the millions of QPS probably caused their network team some headaches in consuming bandwidth, but I digress...  At Turnitin, we also employed cascading replication -- not just for scaling read traffic, but also as a mechanism for high-availability and disaster recovery.  When shipping WAL files to a different region, we were able to have a completely identical cluster of databases -- 1 primary and 4 standbys -- and performing a failover was just a matter of changing a CNAME to direct write traffic to the new location.  From there, we could use tools like `pg_rewind` to re-attach the old region to the new primary region.

## Conclusion
It's interesting and reassuring to see that 15 years later, some of the same solutions we used at Turnitin are being used by one of the biggest Postgres deployments in the world.  This only affirms the fact that Postgres is indeed "The World's Most Advanced Open Source Relational Database."  The Postgres community is incredibly talented, their expertise is deep, and their code is robust.  Even tools like pgBouncer are incredibly reliable, suitable for ultra-heavy, millions-of-QPS workloads.  Power to Postgres! 🐘
