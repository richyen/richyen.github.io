---
layout: post
title:  "Zombies!!  Dealing with a Case of Stuck TransactionIDs"
date:   2019-01-08 13:45:00 -0800
tags: replication xid wraparound postgres PostgreSQL
comments: true
categories: replication postgres
---

# The Story
Postgres is up and running, and things are humming along.  Replication is working, vacuums are running, and there are no idle transactions in sight.  You poke around your logs and make sure things are clean, but you notice a little warning:

{% highlight text %}
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT HINT:  Close open transactions soon to avoid wraparound problems.
{% endhighlight %}

Strange.  There are no open transactions.  You look in `pg_stat_activity` once, twice, three times--nothing.  What's up with that?  How long has this been happening?  You go back to you logs and you throw the whole thing into `grep` and find:

{% highlight text %}
$ cat db1.log | grep "WARNING"
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:38 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:55 GMT WARNING:  oldest xmin is far in the past
2019-01-03 07:51:55 GMT WARNING:  oldest xmin is far in the past
...
$ cat db1.log | grep "HINT"
2019-01-03 07:51:38 GMT HINT:  Close open transactions soon to avoid wraparound problems.
2019-01-03 07:51:38 GMT HINT:  Close open transactions soon to avoid wraparound problems.
2019-01-03 07:51:38 GMT HINT:  Close open transactions soon to avoid wraparound problems.
2019-01-03 07:51:38 GMT HINT:  Close open transactions soon to avoid wraparound problems.
...
{% endhighlight %}

Uh oh.  What's going on?  And the pressure is on--nobody wants to be stuck dealing with wraparound problems.  The adrenaline rush hits, and you're frantically looking for the silver bullet to kill off this problem.  Kill.  Maybe restart the database?  No, you can't do that--it's a production server.  You'll get chewed out!  You look everywhere.  `autovacuum_freeze_max_age`, `pg_class.relfrozenxid`, even `pg_prepared_xacts` and `pg_prepared_statements`.  Nothing.  You try `VACUUM`ing the entire database, but to no avail.  And in the logs, you see the unnerving autovacuum message that `2019-01-03 07:52:48 GMT DETAIL:  ### dead row versions cannot be removed yet.` for several tables.  You ask your colleagues, and nobody's got answers.  You take a deep breath and decide it's time: `pg_ctl restart`

The database goes down, comes back up, and all the apps start connecting again.  But the messages keep on coming: `WARNING:  oldest xmin is far in the past`.  You've got a real zombie on your hands.  And it's not a dream.

# The Unturned Stone
The solution for this scenario is in a seemingly unlikely place: `pg_replication_slots`.  So it turns out that in this scenario, someone had set up a replication slot, used it, but stopped using it.  They didn't clean up after themselves and left the replication slot lying around.  We've seen this problem before, where the `pg_xlog/` partition (a common practice for many DBAs) would with WAL files and bring down the server.  In this scenario, `pg_xlog/` was sufficiently sized and didn't suffer the filling-up that most people with stray replication slots encounter.  Over time, XIDs advance, and the stray replication slot is still waiting for a subscriber to send all its stashed-away data to, leading to the warning and hints as seen above.

# Conclusion
Clean up after yourself.  My wife tells me that all the time.  I tell it to my kids as well.  Do it with your database too.  Vacuum, remove unused indexes, close out your transactions, and remove your unused replication slots.  It's good for your server, it's good for the environment, and it's good for your health.  Have a Happy 2019!

*Special thanks to Andres Freund for helping with the analysis and determining the solution*
