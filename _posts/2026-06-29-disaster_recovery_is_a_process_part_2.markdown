---
layout: post
title:  "Disaster Recovery is a Process, Not a Tool (Part 2)"
date:   2026-06-29 00:00:00 -0800
tags: PostgreSQL postgres disaster-recovery dr rto rpo runbook game-day high-availability operations
comments: true
categories: postgres
---

## Picking Up Where We Left Off

In the [previous post](/postgres/2026/06/15/disaster_recovery_is_a_process.html), I tried to lay out the framing half of this material: what actually counts as a disaster, why preparation and prevention aren't the same as recovery, and how RPO and RTO end up being conversations with leadership rather than numbers an infrastructure team gets to declare on its own.

That part is largely about understanding the problem.  This part is about actually building the capability to deal with it.  And in my experience, this is where most teams quietly stumble -- not because they don't have backups or replication, but because they've never really practiced using either of them under stress.

## Runbook Engineering: Why Runbooks Fail

Once you've accepted that DR is a process, the natural next step is to write some runbooks.  And in my experience, this is where a lot of teams quietly stumble.

Runbooks usually get written by experts, for experts, in a calm conference room.  That's almost the opposite of the environment they'll actually be run in.  Real recovery happens at 3AM, under stress, often with incomplete information and sometimes with someone who isn't deeply familiar with the system.  A runbook's job, really, is to *reduce ambiguity* in that moment -- not to be a comprehensive description of the system, but to be the thing you can follow even when you're tired and scared.

That framing alone changes what a good runbook looks like.

### Anti-patterns

A few patterns I see often that make runbooks worse, not better:

- **Giant wiki pages.**  I think a lot of teams try to kill two birds with one stone by sprinkling DR steps inside their general system documentation, so they don't have to maintain a separate doc.  What you end up with is something that's hard to follow under stress, and that drifts quietly as the surrounding documentation evolves.
- **Stale commands and hostnames.**  Infrastructure changes over the years.  Commands that worked in Postgres 11 are sometimes not quite right anymore.  I've definitely been the person who wrote a runbook step that turned out to be wrong by the time anyone needed it.
- **No rollback criteria.**  If the runbook tells you to run a command, it should also tell you what success and failure look like, and what to do if the command does something unexpected.
- **No clear ownership.**  Everyone wants to ship the next feature, expand the cluster, do the upgrade.  Updating the runbook is the thing that gets put off.  In my experience, this works best when the reliability engineering team owns the runbooks explicitly, rather than treating them as collective property nobody is really responsible for.
- **Vague instructions.**  "Inspect the logs for errors or warnings" is a step I see all the time.  But *where* are the logs?  Every organization seems to put them in a slightly different place.  When I drop into a customer's database server, finding the Postgres log is often surprisingly nontrivial -- and that's the most important source of information about the health of the system, so it really shouldn't be a scavenger hunt.

### What a good runbook looks like

A good runbook is procedural and deterministic.  It tells you "this is the situation; here is exactly what to do."  If split brain happens, what command do you run?  If replication lag is over a certain threshold, do you fail over or wait?  Those decisions should already be made, by the people who had the luxury of making them calmly.

Instead of "fail over to the read replica," a good runbook says which replica, what the promotion command is, what to check after promotion to make sure it actually worked, and what to do if it didn't.  It includes the pre-flight checks before you bring traffic back, and the rollback path if the recovery itself goes sideways.

### Non-technical essentials

The non-technical pieces are easy to overlook, and in my experience they make at least as much difference as the technical ones.

One thing I really appreciated when I worked in EDB Support was that every ticket had a clearly designated commander -- the person who talked with the customer, gathered the information, and directed the other support engineers.  That role makes a huge difference in an incident, because somebody needs to be coordinating, and it generally shouldn't also be the person at the keyboard.

When I moved to Microsoft, I noticed an additional layer that I'd underrated before: a separate **communications owner**.  When Azure has an incident, there's an incident commander focused on getting the system back up, *and* there's a different person whose job is to communicate -- via email, social media, status pages, Discord, whatever the channel is -- so customers know what's happening and what to expect.  Splitting those two roles takes a lot of pressure off the technical recovery, and I'd recommend it to anyone running services that customers notice.

Beyond those two roles, a few other things really do belong in the runbook:

- **Stakeholder notification cadence.**  Even if there's no new information, telling stakeholders "no change, still working on it" every fifteen minutes is far better than silence.
- **A clear escalation chain.**  Primary on-call, backup on-call, the right engineering contact, the business owner.  In my experience, escalations to engineering often happen a little prematurely -- and a little unclearly -- because nobody mapped out who specifically to call.
- **Customer impact thresholds.**  At what point do we change our response posture?  If more than half our customers are affected, what changes?
- **Risk authorization.**  Some recovery actions are dangerous on their own -- restoring a month-old backup, accepting data loss, dropping a replication slot.  Who is authorized to make those calls, and how do you reach them?

### Validation

Once you have a runbook, you have to actually validate it.  Some questions I think are worth asking:

- Can a new engineer follow it?  This is genuinely worth testing.  I think it's a fine onboarding exercise to take a dev environment, break it in a controlled way, hand the new hire the runbook, and see if they can get it back.  If they can't, that's not a failing of the new hire -- it's feedback on the runbook.
- Does the runbook assume privileged access the people running it won't have under stress -- passwords, certificates, VPN, bastion access?
- Are the specifics still right?  Hostnames change.  Schemas change.  Resource group names change.  The runbook needs to drift with them, or, better, be re-tested often enough to catch the drift.

Honestly, keeping runbooks current is close to a full-time job at any reasonably-sized organization.  I think it's reasonable for it to *be* somebody's main job -- regularly talking to teams, keeping the docs aligned with the infrastructure, organizing the drills.

## Game Days

Which brings me to game days.  In my experience, this is where DR shifts from a document to an actual capability.  A DR plan is not really proven by the fact that it exists; it's proven through repeated, successful execution.

We started doing this at Turnitin around our release cycle.  For a meaningful release, we'd set up an environment that was as close to production as we could make it -- same hardware where possible, same CNAMEs, maybe just a different subnet -- and we'd practice the release on it.  It started as a release-rehearsal habit, but the same idea applies to DR: a controlled failure simulation designed to test the systems, the procedure, the coordination, and -- maybe most importantly -- the assumptions people are quietly making.

I think it helps to think of game days as having levels you grow into.

You start simple: restore a backup, promote a standby, redirect traffic, validate that the application actually behaves correctly after the cutover.  Just being able to do that end-to-end, on demand, puts you ahead of a lot of teams.

Then you start adding pressure.  Give the team an SLA on the drill -- "we're going to break something at 10:00 AM, and you have 30 minutes to be back up."  This is where you find out what your actual achievable RTO is, as opposed to the aspirational one in the spreadsheet.

Then you start adding chaos.  What if the person who normally runs the failover is unavailable?  What if a certificate has expired and now you have to renew it while the outage is happening?  What if you scheduled the drill -- not entirely by accident -- on a day when a key engineer happens to be on vacation?  These sound mean, but they're realistic.  Real incidents are not polite about your team's calendar.

A few practical rules I've found useful for running drills without making things worse:

- Start in staging or on a standby; not on the production primary.
- Schedule the drill and announce it.  The *drill* is the surprise; the *date* is not.  You're testing the runbook, not your team's reflexes at 2AM on a holiday.
- One failure mode per drill, at least at first.  Don't combine "disk fails AND network partitions AND VP of Engineering is on a plane" until you've nailed each of those individually.
- Define what success looks like before you start.  "We restored within 30 minutes" is testable.  "It went well" is not.
- Run a retro within a couple of days, while it's still fresh.

## What to Measure

When you finish a drill (or a real incident), the obvious thing to measure is "did recovery succeed?"  That's important, but it's also kind of binary, and you'll learn more from the other things you can measure:

- How long did each phase take -- detection, decision-making, execution, validation, communication?  That's where you'll find your real bottlenecks.
- Where did the runbook turn vague?  Anywhere a participant had to ask "wait, what does this mean?" is a small documentation bug worth fixing.
- Which dependencies turned out to be undocumented?
- Which credentials or permissions were missing or expired?
- How close were the actual results to the stated RTO and RPO?  If the gap is big, that's important information for the next conversation with leadership.

## Don't Blame, or You'll Feel Lame

I want to spend a minute on the cultural side, because I think it might matter as much as the technical side.

Incidents and drills are stressful.  I don't think we always give that enough weight -- we're more comfortable thinking about CPU and IOPS than we are about the very real fact that people freeze under pressure, or hide uncertainty, or act too quickly to make the discomfort go away.

In a blame-heavy environment, people shrivel up.  They stop volunteering information.  They don't want to admit they don't know something, or that they did something that didn't work, so they make assumptions instead of asking.  What you end up with is delayed escalations, silent failures, and risky decisions made by people who didn't feel safe enough to talk through their thinking.  None of that helps your RTO.

The opposite culture -- one that encourages people to verbalize what they're seeing, what they're not seeing, and where they need help -- is much harder to build than a runbook, but pays off in every incident.  Post-incident reviews really should be about improving the system, not punishing the person.  And when a drill or a real recovery is hard, I think it's genuinely worth acknowledging that out loud.  Order pizza, go out for sushi, do something to thank the team.  It's not a substitute for fixing the technical gaps, but it does make people show up to the next drill.

## Wrapping Up

If I had to compress this whole series into one line, it would be roughly this: **make your RPO worth it by investing in your RTO.**

Lower RPO is something you can largely buy -- with replication, with hardware, with cloud spend.  Lower RTO isn't really something you can buy.  It's something you build, slowly, with runbooks, drills, retrospectives, and a culture that treats incidents as opportunities to learn instead of opportunities to assign blame.

Tools and AI both have a place in this work, and the tooling around Postgres is genuinely good.  But in my experience, the difference between a team that handles a disaster well and one that doesn't isn't usually the tools they had -- it's the process they'd practiced.

If nothing else, I'd suggest picking a day next month, killing a replica in a safe environment, and seeing what happens.  The first drill is almost always the most informative one.  Good luck out there!
