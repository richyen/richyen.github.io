---
layout: post
title:  "Disaster Recovery is a Process, Not a Tool (Part 1)"
date:   2026-06-15 00:00:00 -0800
tags: PostgreSQL postgres disaster-recovery dr rto rpo high-availability operations
comments: true
categories: postgres
---

## The Landscape Has Changed

When I was at Turnitin, we were still kind of riding the tail end of the dot-com boom.  People were rushing to ship things, and brief outages were not exactly *good*, but they were considered a normal part of running software on the internet.  If the site was down for a few minutes, you'd shrug, dig in, and fix it.

That's not really the world we live in anymore.  Uptime is much more sensitive than it used to be.  Five nines used to be the stretch goal -- now four nines is something a lot of teams just treat as the expectation, and even a few minutes of outage in a month feels like a lot.  We don't really track averages in our metrics anymore, either; we track p99 latencies, because we actually care about that last 1% of users having a good experience.

The other thing that's changed is how quickly outages get socialized.  A noticeable hiccup in your service can end up on social media before your on-call has even finished acknowledging the page.  In my experience, the worst situations are the ones where customers find out about an issue before the company does.  That has both a financial cost and a reputational cost, and the reputational cost tends to linger long after the incident is resolved.  Frequent outages chip away at users' willingness to keep using your product.

Postgres is, of course, no exception.  So that's the world a Postgres DR plan has to operate in.

## What Counts as a Disaster?

When people hear "disaster recovery," I think the natural mental picture is a natural disaster -- a flood, an earthquake, a wildfire, or maybe a long utility outage that takes a data center offline.  And those are real concerns; we put generators and solar panels and multi-region replication in place partly to deal with exactly that.

But in my experience, most of the disasters that take a Postgres database down don't look anything like that.  They look like:

- A performance regression after a failover, where the service is technically "up" but slow enough that customers can't really use it.
- Corruption from a bad migration -- something the deployment pipeline didn't catch, and now half the rows in a table look wrong.
- A security incident, where somebody got in and may have tampered with data.
- A subtle application bug that writes the wrong values, or reads them back the wrong way, for days before anyone notices.
- Replication that quietly broke, or WAL that quietly went missing.
- Accidental deletes -- the classic missing `WHERE` clause.

If I had to put a definition on it, I'd probably say something like: a disaster is any sustained event that compromises a system's availability, correctness, or business trust.  Availability is the one that gets the most attention, but the other two are arguably more dangerous, because they tend to be discovered later and resolved with less confidence.

## How DR Is Usually Done

If you ask most teams how they do disaster recovery, you'll usually hear two words -- not because they're wrong, but because they're the first things that come to mind.  Those words are **preparation** and **prevention**.

Preparation looks like checklists, backups, monitoring, scenarios to think through, and playbooks of various levels of detail.  Prevention looks like alerting, automated remediation, self-healing systems, Patroni, redundancy, load balancing, and so on.  Both are good.  Benjamin Franklin's "an ounce of prevention is worth a pound of cure" is on the wall of more than one ops team I've worked with, and there's a reason for that -- prevention really is cheaper than recovery on average.

But preparation and prevention only get you so far, and I don't think they're really the same thing as recovery.  Recovery is what happens after preparation and prevention have already failed to keep the lights on.  It's the act of taking a system that's already down (or already untrustworthy) and restoring business operations.

That distinction sounds almost too obvious to say out loud, but in my experience it's the part teams are least ready for.  A lot of the customers I worked with at EDB were genuinely well-prepared, with great backups and good monitoring, and they were *still* unprepared the day they actually had to recover.  I've been in that seat too, as a DBA -- everything was in place on paper, and we still fumbled the first real incident.  Recovery is its own skill.

## Postgres Already Gives Us Most of the Tools

One nice thing about Postgres is that the toolbox for recovery is already pretty good.  Off the top of my head, there's `pg_dump` and `pg_restore` for logical backups, `pg_basebackup` for physical ones, `pg_stat_replication` to see what your standbys are doing, `pg_stat_activity` to see what your sessions are doing, point-in-time recovery for anything more granular than "last night's backup," and tools like [repmgr](https://www.repmgr.org/) and [EFM](https://www.enterprisedb.com/docs/efm/latest/) (and pgBackRest, Barman, and others) for orchestration and richer backup workflows.

These tools are not the bottleneck.  In nearly every case I worked at EDB, the question wasn't "do we have the technology to recover?"  It was, "do we know *when* to use it, *how* to use it, and *who* gets to make the call?"  I had a customer once who had perfectly good backups -- they really did -- but they opened a P1 ticket asking me to walk them through the keystrokes for the restore.  I think they actually knew what to do; they were just afraid, in the moment, of typing the wrong thing.  That's a process gap, not a tool gap, and no amount of additional automation would have fixed it.

I'd add a slightly uncomfortable note here: as a vendor's support engineer, I was always happy to help, but we probably shouldn't be the centerpiece of anyone's DR plan.  Support engineers can hand you tools and walk you through documentation, but we don't know your data the way your team does, and there's a liability we're not really supposed to take on.  If the first time a team reads the failover documentation is during the outage, a support contract alone isn't going to close that gap.

## RPO and RTO, and Why They're Negotiations

You can't really talk about recovery without talking about RPO and RTO, so let me do that briefly.

**RPO** (Recovery Point Objective) is roughly "how much data are we willing to lose?"  Do we restore from last night's backup and accept losing the day's writes?  Or do we replay WAL and try to get as close as we can to the moment of the outage?

**RTO** (Recovery Time Objective) is "how long are we allowed to be down before we're considered back up?"

Every choice on either of these axes is a trade-off -- against cost, against complexity, against operational burden, against acceptable business loss.  And the reality is that during an outage, you really are losing business; transactions don't happen, shopping carts don't get checked out, customers get frustrated.  At the same time, getting up faster usually means accepting more data loss, or paying more for the infrastructure to avoid it.

It's helpful to think about RPO in tiers:

- A **24-hour RPO** is basically "restore last night's backup."  One or two people can usually handle it, the moving parts are simple, and the data loss can be substantial.  That's fine for some workloads.  It's not really acceptable for high-traffic services where 24 hours of writes is a lot.
- A **15-minute RPO** generally means WAL archiving or shipping, monitoring to make sure none of that WAL goes missing, regular validation that you can actually restore in 15 minutes, and operational discipline around retention.  That's reasonable for many systems, but probably not acceptable for, say, a financial institution.
- A **near-zero RPO** typically means synchronous replication and tightly managed failover.  Now you're dealing with latency between nodes, distributed-systems complexity, split-brain scenarios, and a much bigger operational footprint.

Lower RPO isn't just "better."  It's a design and operational commitment, and that commitment costs money, time, and people's attention.

The same is true of RTO.  Driving RTO below five minutes generally requires automation and -- this part is important -- rehearsal.  If you hand someone a document for the first time during an actual outage, they are not going to execute it quickly, no matter how clear the document is.

This is why I think RPO and RTO really need to be *negotiated*, not just declared.  On the surface it's almost a no-brainer -- of course everyone wants an RPO of zero and an RTO of seconds.  But when you actually go to leadership and lay out what those numbers cost, you tend to find out pretty quickly where their priorities really sit.  In a lot of cases, they'd rather spend that money on something that looks more directly tied to the business -- a new feature, a marketing push, another engineer on the product team -- and they're willing to accept a softer RPO or RTO in exchange.  That's a legitimate answer; it just needs to be made explicitly, instead of being assumed one way or the other by the infrastructure team.

## Three Layers of DR Planning

When I think about what a DR plan needs to cover, I find it useful to break it into three layers.

The first layer is **infrastructure failure**.  This is the one most teams think of first: a region goes down, storage fails, a corruption bug bites, credentials leak, somebody accidentally deletes a table, replication breaks.  Hardware and platform behaving badly.

The second is **procedural failure**.  Even if the infrastructure problem is well-understood, you can still fail recovery because the procedure is wrong.  Maybe the sequence values weren't included in the backup and you didn't realize.  Maybe the runbook references a CNAME nobody can find the host for anymore.  We used to have a setup at Turnitin where, on every failover, we had to repoint a CNAME to the new primary, and we eventually realized that nobody had documented which CNAME pointed to which underlying host.  Maybe the validation step is vague.  Procedural failure tends to be invisible until the moment you actually need the procedure.

The third is **human failure**.  People behave differently under duress.  Some panic.  Some zone in so hard on one screen that they miss the bigger picture.  There are conflicting instructions between managers, between teams, between people trying to be helpful.  There's the 3AM call where the on-call is barely awake and not entirely sure what's going on.  And there's the person who can't wait for the process and decides to just do something heroic and fast -- which sometimes works, and sometimes makes things significantly worse.

To make the layers concrete: I had a 3AM incident at Turnitin once where we rolled out a change in the evening and got paged a few hours later.  The disk had filled, and the filesystem ended up unmounted.  That was the infrastructure failure.  In the scramble to bring it back, somebody tried to remount it as `ext4` instead of `xfs` -- that was strike one, a procedural failure, because the runbook didn't make the filesystem type explicit.  Then we sat for a while waiting on the CTO, because nobody on the bridge had clear authority to call any of the next steps -- strike two, no incident commander.  And then somebody prematurely brought the web servers back up before the database was really healthy, causing a second round of errors -- strike three, the hero move.  No single one of those was catastrophic; together they turned a one-hour problem into a much longer night.  That's what the three layers look like in practice.

## Recovery Isn't Always About Failing Over

A lot of DR talks (and a lot of DR vendors) make it sound like "recovery" basically means "fail over to the standby."  That's one tool in the box, but it's nowhere near the whole box.

Here's a story that's stuck with me.  I was on a small team that shipped a release, and the migration looked clean -- everything came up, the smoke tests passed, we went home feeling pretty good.  Later, somebody noticed that the application code had a small typo in its SQL: an extra apostrophe was getting written into every comment in a comment thread.  The data wasn't lost.  The system was up.  But the data was *wrong*, and it kept getting more wrong every minute the application stayed online.

In that particular case, a careful `UPDATE` across the table was probably the right call, with all the locking and performance impact that implies.  But if you change the details a little -- say the corruption is medical records, or it isn't discovered for a few days, or some of those rows have already been read by other systems and propagated outward -- a simple `UPDATE` stops being the answer.  Now you're asking whether you have enough WAL retained to do point-in-time recovery, whether you can safely update some rows in place, when exactly the corruption started, and so on.

I bring it up because that scenario is just as much a disaster, and just as worth planning for, as a disk failing or a region going dark.  And it can't be solved by failing over -- the standby would have the bad data too.

While I'm telling stories about quietly-bad situations: another underrated failure mode is "the engineer who knew this part of the system went on vacation," or quit, or moved teams, and the documentation never quite got updated.  Real DR plans have to assume some of that, too.

## What Lower Numbers Actually Cost

Negotiating RPO and RTO sounds abstract until you start listing the consequences.  Wanting an RPO of zero pushes you toward synchronous replication and forces you to live with the latency that comes with it.  Wanting an RTO of under five minutes pushes you toward automation that has to be built, tested, and maintained, and toward rehearsal cadence that has to be on someone's calendar.  Multi-region pushes operational complexity up significantly -- you've got clusters in different regions talking to each other, you've got cross-region replication lag to tolerate, and now your monitoring story has to account for all of it.  Even something as innocuous as "we'd like to be able to do point-in-time recovery to any second over the last 30 days" can mean keeping terabytes of WAL around and paying for storage you barely look at.

None of this is a reason not to do these things.  It's just a reason to have honest conversations about which of them you actually need.

## To Be Continued

That covers what I think of as the framing half of the talk: what counts as a disaster, why preparation and prevention aren't the same as recovery, and how RPO and RTO end up being negotiations rather than declarations.

In two weeks, I'll get into the part that I think could reduce RTO (something that can't be replaced by AI): runbook engineering, game days, what to measure, and the cultural piece that holds it all together.

