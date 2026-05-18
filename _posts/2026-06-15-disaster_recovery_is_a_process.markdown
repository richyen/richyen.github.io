---
layout: post
title:  "Disaster Recovery is a Process, Not a Tool"
date:   2026-06-15 00:00:00 -0800
tags: PostgreSQL postgres disaster-recovery dr rto rpo runbook game-day high-availability operations
comments: true
categories: postgres
---

## Introduction

It's 3AM.  My wife shakes me awake -- my phone is buzzing.  I roll out of bed, walk through a cold house to my desk, and join the chat.  The website is hanging and students can't submit papers.  We start filtering through symptoms while we wait for everyone else to climb out of bed and get on the bridge.  The CTO is the de-facto incident commander.  A few minutes later, somebody finally runs the right command and we get our answer: **Input/Output error**.  The filesystem is mounted, but `ls` gives us an error message in the terminal -- the disk has failed.  By the time we agree on a plan (promote the standby, have the sysadmins swap the disk in the morning, rebuild the old primary as a new standby), it's 4AM.  I'm back in bed at 5:30.

What I just described is what military folks call the *fog of war* -- incomplete information, unclear authority, and time pressure all at once.  In my experience, both as the on-call engineer at Turnitin and later as a Support Engineer at EDB, a lot of disaster recovery (DR) planning is really about trying to cut through that fog *before* the pager goes off.

---

## What Counts as a Disaster?

After Turnitin, I joined EDB and spent years on the support side of the phone.  One thing I noticed pretty quickly is that disasters happen -- big and small -- and not every team is as ready for them as they think they are.

So what counts as a disaster?  I tend to use a fairly broad definition: **anything that meaningfully affects the reliability or availability of the database layer** is worth treating as one.  It doesn't have to be a meteor strike.  Practically, most of the disasters I see fall into four categories:

- **Hardware failure** -- like the 3AM disk incident.  I've also heard from someone recently about RAM sticks going bad too.
- **Logical corruption** -- a bad deploy that ran the wrong migration, or a developer reviewing data who forgot a `WHERE` clause and updated every row.  Self-healing won't fix these kinds of disasters.
- **Malicious actor** -- ransomware, or a disgruntled insider with `DROP` privileges.
- **Human error**

Some of these can be prevented with good monitoring and tooling.  When prevention falls short, what tends to save the day is **process**.  Tools like [repmgr](https://www.repmgr.org/) or [EFM](https://www.enterprisedb.com/docs/efm/latest/) do a great job of performing a failover, but knowing *when* to use them, *who* gets to call it, and *what* happens after isn't really a tool problem -- it's a process problem.

One way I like to think about it: **a runbook is a DBA's test suite**, and a Game Day is the integration test you run in a production-like environment.  Reliability tends to track pretty closely with how often a team has practiced losing it.

---

## RTO and RPO: The Numbers That Drive Everything

Before you write a single runbook, you need two numbers from the business:

- **RTO (Recovery Time Objective)**: how long are we allowed to be down?  Put another way, how long do we have before we need to declare "the disaster is over"?  This is a business decision, not a DBA decision.  It requires conversation with leadership.  A lower RTO is achievable, but it's expensive -- it requires structure, automation, and rehearsal.  Well-written and well-practiced runbooks will drive down the recovery time and get you to meet that RTO number.
- **RPO (Recovery Point Objective)**: how much data are we allowed to lose?  Failing over to a standby that already had replication lag will cost you some transactions.  Restoring from a backup might cost you hours of writes.  There's a give-and-take between RPO and RTO, and again, this is a business decision.

Both can be driven low, but doing so usually costs time, money, and headcount.  If leadership is hoping for a 5-minute RTO and zero RPO, they need to be prepared to fund things like cascading replication, synchronous standbys, deeper monitoring, and regular drills.

---

## Support Engineers Are Not Your DR Plan

A pattern I saw a few times while at EDB:

- Customers opening a P1 ticket asking for the steps to restore a backup
- Customers asking how to fail over to a standby -- *while the primary was already down*
- "Can you stay on the bridge with us?"

I was always happy to help -- that's the job.  But it's worth saying gently: a vendor's support team probably shouldn't be the centerpiece of a DR plan.  We can hand over tools, walk through documentation, and help drive a recovery.  However, we can't make business decisions on your behalf, define RPO, practice runbooks, or serve as the named incident commander.  Support Engineers cannot be expected to be DBAs, primarly because of lack of knowledge about a customer's data layer, not to mention the liability that we're not supposed to take.

If the first time a team reads the failover documentation is during the outage itself, that's a sign there's a gap a support contract alone isn't going to close.

---

## The Boring Win: A Story About a Release

Not every story I have from Turnitin is a 3AM disaster.  Here's one that went the other way.

We had a major release coming up -- the kind with schema changes, data migrations, and a hard maintenance window.  As part of the release planning, we wrote out every command, in order, copy-pasteable.  We practiced it in dev and in staging.  On release day, we executed the plan, finished early, well before the end of the planned maintenance window.

I bring up the release because in a lot of ways, releases and disasters look pretty similar from an operational standpoint: high-stakes, time-bounded, multi-step procedures executed under pressure.  The reason that release went well is roughly the same reason a DR plan tends to work -- we'd rehearsed it.  After that release, we started building out runbooks for DR scenarios using a similar approach.

A few things from the release that I think translate well into DR planning:

- **Commander vs. Operator.**  The release plan had a *named commander* on the doc, and that small thing made a big difference.  The Commander runs the call and owns communication; the Operator owns the keyboard.  Trying to do both jobs at once tends to go badly.
- **Copy-pasteable commands.**  At 3AM, tired, most of us would rather not be composing `pg_basebackup` invocations from memory.  A runbook that lets you execute, rather than improvise, takes a lot of pressure off.
- **Decision trees, not prose.**  "If X, do Y; otherwise, do Z" is a lot easier to follow at 3AM than a paragraph of explanation.

This is also part of why a wiki page on its own often isn't quite enough.  A wiki tends to describe the system; a runbook tells what to type next.  Wikis can drift quietly over time, while runbooks tend to fail loudly the first time you drill them -- which, honestly, is exactly when you want them to fail.

---

## A Framework: Detect → Decide → Restore → Validate → Communicate

Most runbooks I've worked on end up fitting into roughly the same five phases:

1. **Detect** -- monitoring caught it, or a human did.  How do you confirm what's actually broken?
2. **Decide** -- who calls it?  What's the threshold to declare an incident?  Who is the Commander?
3. **Restore** -- the actual recovery steps.  Failover, restore from backup, kill the bad query, revert the deploy.
4. **Validate** -- is the database actually healthy?  Are reads and writes succeeding?  Did replication catch back up?
5. **Communicate** -- status page, customer comms, internal stakeholders, post-incident timeline.

Each scenario gets its own runbook walking through those five phases.  Some examples worth having on the list:

- Failed disk
- Failed replica
- Lost data (the missing-`WHERE`-clause case)
- Corrupted data
- OOM / memory pressure
- Network partition (the "someone removed a VPC" case)
- Ransomware / unauthorized `DROP`
- Failed deploy / bad migration

You don't need all of these on day one.  Even one, tested, with a plan to write the next, puts you in much better shape than most teams.

---

## Where Does AI Fit?

My honest take is that AI is genuinely useful in DR work -- but it's most useful in the parts of the framework where the answer is fairly mechanical, and least useful in the parts where judgment matters most.

Where I think AI can help quite a bit:

- **Detect.**  Anomaly detection on metrics, log summarization, correlating a spike in `pg_stat_activity` with a deploy that just landed -- this is the kind of pattern-matching work AI is good at, and it can absolutely shorten the time between "something is weird" and "here is what looks weird."
- **Drafting runbooks.**  Generating a first pass of a runbook from a description of an architecture, or suggesting edge cases you may not have considered, is a reasonable use of an LLM.  Just treat the output as a draft your team reviews and tests, not as a finished artifact.
- **Assisting the Operator.**  Summarizing what's happened on a long incident bridge, surfacing relevant past incidents, suggesting the next diagnostic command -- all of that can reduce the cognitive load on whoever is at the keyboard at 3AM.
- **Post-incident.**  Writing a first draft of a timeline from chat logs and metrics is a chore that AI handles reasonably well, freeing humans to focus on the *why*.

Where I'd be more cautious:

- **Deciding whether to declare an incident.**  This is a judgment call that involves business context, customer impact, and political nuance an AI usually doesn't have.
- **Picking which runbook to run.**  Two scenarios can look very similar in metrics and be very different in cause -- a failed disk and a network partition can both present as "primary unreachable."  Picking the wrong runbook can make things worse.
- **Executing destructive commands unattended.**  Promoting a standby, dropping a replication slot, running `pg_resetwal` -- these are easy to get wrong and very hard to undo.  I'd want a human in the loop for any of them, even if AI is suggesting the command.
- **Owning communication.**  Customers and stakeholders need a human accountable on the other end, especially when the news isn't good.

The way I'd frame it: AI can do a lot of the work of *noticing* and *suggesting*, and it can take some of the toil out of running and writing runbooks.  But the **decisions** -- which runbook applies, when to declare, when to fail over, when to call it done -- still want a human's name on them.  In the framework above, AI tends to be most helpful around Detect, parts of Restore, and Communicate (drafting, not sending).  Decide is still mostly a human's job, and probably should be for a while.

A practical rule of thumb I've started using: **if it's reversible, AI assistance is great.  If it's not, a human MUST sign off.**

---

## Game Days: The Drill Is the Point

In offices and schools throughout the world, there are fire drills, earthquake drills, and tornado drills.  Every professional sports team spends hours each day practicing plays so that on Game Day, they all know what to do and where to go.

Database engineering teams benefit from doing something similar.

Writing a runbook is really only half the work.  The other half is *running* it.  A controlled burn -- an intentional outage, on a dev or staging environment, or even on a standby in production -- ideally lives somewhere on the team's roadmap rather than in the "we'll get to it" pile.

There's a saying that "a backup isn't really a backup until you've restored it".  I think the same applies to runbooks: until you've drilled one, you don't really know whether it works.

A few rules I've found useful for running drills safely:

- **Start in staging or on a standby.**  Never on the prod primary first.
- **Schedule it and announce it.**  The *drill* is the surprise; the *date* is not.  You're testing the runbook, not your team's reflexes at 2AM on a holiday.
- **One failure mode per drill.**  Don't combine "disk fails AND network partitions AND VP of Engineering is on a plane."
- **Define the success criterion before you start.**  "We restored within 30 minutes" is testable.  "It went well" is not.
- **Run a retrospective within 48 hours,** while memory is fresh.

One more thing that doesn't really fit on a checklist but I think matters as much as any of them: **blameless retrospectives**. It needs to be clear that the purpose of the retrospective is to identify any areas where the runbook can be improved or clarified, not how an engineer failed to perform a task or a commander failed to call out a step. 

---

## Conclusion

If I had to summarize all of the above in a sentence, it would be that disaster recovery is mostly a process, and that process is captured in runbooks.  "Trust the process" usually means following the runbook even when your instinct disagrees -- a bit like following a cake recipe even though it looks like more butter than seems right.  A good process also tends to improve over time: every drill, every retro, and every real incident is a chance to make the next one a little more boring.

Tools and AI both enable DR work.  Process and the people running it are what tend to keep the business intact when something actually goes wrong.

If nothing else, I'd suggest picking a Tuesday next month, killing a replica in a safe environment, and seeing what happens.  The first drill is almost always the most informative one.  Good luck!
