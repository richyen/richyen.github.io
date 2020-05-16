---
layout: post
title:  "Don't Leave Me Hanging: Another Type of Transaction to Monitor"
date:   2020-05-22 13:00:09 -0800
tags: PostgreSQL postgres prepared_transactions transactions pg_prepared_xacts twophase
comments: true
categories: postgres
---

# Introduction
People who have worked with databases for a number of years will inevitably have encountered situations where some abandoned session caused table locks never to be released and basically ground a service to a halt.  The most frequent culprit is an idle transaction on an open `psql` session behind a `screen` session on someone's development server.  This occurred so frequently that in 2016, Vik Fearing, Stéphane Schildknecht, and Robert Haas introduced `idle_in_transaction_session_timeout` into Postgres' list of parameters in the release of version 9.6.  However, an uncommitted idle transaction isn't the only way to stick a wedge in the gears of a database system.  Another one that we'll discuss today involves **prepared transactions**, which have the potential to do the same thing.

# What's a Prepared Transaction?
Prepared transactions are Postgres' implementation of two-phase commit.  The aim of this feature is to synchronize the commit of several transactions as though they were one transaction.  A possible use case for this is a system where there are several databases (think several intentories across geographic regions -- something of that sort), and all need to be updated at the same time.  The typical set of prepared transactions might look something like this:
1. Issue `BEGIN` on any relevant database/node
1. Do your CRUD
1. Issue `PREPARE TRANSACTION 'any_custom_transaction_name'` to disassociate the transaction from your `pid` and store it in the database
1. Once all databases/nodes have successfully finished the `PREPARE TRANSACTION` step, and you're ready to commit, issue `COMMIT PREPARED 'your_transaction_name'` to commit the changes to disk.

If at any point there's an error and the transactions need to be rolled back, a `ROLLBACK PREPARED 'your_transaction_name'` will roll back your transaction (this will need to be run on all relevant databases).

# Where's the Danger?
In the third step above, I hinted at the idea that a prepared transaction would be disassociated with your Postgres session/backend.  This means that the state is now held in Postgres' internals, along with all the locks it's acquired.  This is a good thing in that you can synchronize your final commit over a span of time (in accordance with timezones, perhaps).  Another added bonus is that the prepared transaction now can survive a database crash or a restart.  All the transaction information is stored in `pg_twophase` until the `COMMIT` or `ROLLBACK` happens.  However, therein lies the danger--if left uncommitted, a prepared transaction can keep locks forever, preventing database activity from completing, or even preventing a `VACUUM` from doing its job.

Knowing the dangers of orphaned prepared transactions, we can (and should) check the `pg_prepared_xacts` table to make sure nothing stays prepared and uncommitted/unaborted for a long time.  Looking at the `prepared` column of `pg_prepared_xacts` will certainly give an admin clues as to the age of a prepared transaction and whether it can be the culprit of database unresponsiveness.

# Conclusion
While two-phase commit is a great feature for those who need it, it's a feature that rally should only be enabled after careful consideration by application developers and architects.  What makes it extra dangerous is that prepared transactions are not tied to an active Postgres backend, meaning that it has no `pid`, so unless you're monitoring `pg_locks` or `pg_prepared_xacts`, you may not even know one has been created--you definitely won't find it in `pg_stat_acitivity`!.  They are doubly dangerous as they can survive a database restart, inciting great panic in an admin that can't figure out why application traffic has ground to a halt.  The parameter `max_prepared_transactions` in `postgresql.conf` is what enables this feature, and it's set to `0` by default.  Keeping it disabled will prevent any unintended headaches, damage, and outages.  Stay safe!
