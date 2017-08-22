---
layout: post
title:  "Monitoring Replication Lag with EDB Replication Server"
date:   2017-08-22 16:28:09 -0800
tags: xdb replication edb enterprisedb lag monitoring
categories: postgres
---
# Introduction
EDB Replication Server empowers DBAs with high-performance Multi-Master Replication (MMR) with the help of Postgres' Logical Decoding framework.  While performance is a signifiance improvement from the xDB 5.x trigger-based replication architecture, DBAs and sysadmins still seek to monitor and track replication lag.  There are a number of ways to do this, and we'll go over them.
 
# Row Replication Lag
Much like using `pg_stat_replication` when employing Postgres' built-in Streaming Replication, the most accurate form of replication lag monitoring is to see how many bytes (in this case, rows) a standby/target databse is behind its provider.  The way to measure this is by executing the following query on the control databse (in most cases, the MDN):
 
{% highlight text %}
SELECT COUNT(rrep_sync_id) AS pending_rows FROM _edb_replicator_pub.rrep_mmr_txset a, _edb_replicator_pub.rrep_txset_log b WHERE a.set_id = b.tx_set_id AND status IN ('P', 'R');
{% endhighlight %}
 
Note that this is the same query that Postgres Enterprise Manager's (PEM) XDB Replication Probe uses.  If you're already using PEM, you can just enable the XDB Replication Probe, and you'll be able to monitor the lag from the PEM client.
 
# Time Replication Lag
For most people, they're not interested in the number of bytes or rows a replication cluster is lagging behind.  Instead, they're more interested in how long it takes for ALL the unreplicated data to get to the other side.  For this, there's no real way to get a measurement without having a third-party monitoring to see if a change in one server has appeared in another server.  Moreover, in an MMR situation, there are complexities in defining replication lag in terms of wallclock time, since all nodes are Master Databases.
 
One way to measure time lag in an EDB Replication Server cluster involves a few tricks, and the setup looks like this:

. A table dedicated to testing replication performance (we'll call it `xdb_lag_test`)
. A table tabulating the time lag history (we'll call it `xdb_lag_history`)
. A function returning a trigger (named `update_xdb_lag_history`)
. A trigger on the `xdb_lag_test` table

First, we create the `xdb_lag_test` table:
{% highlight text %}
CREATE TABLE xdb_lag_test(
 source_host character varying(50) PRIMARY KEY,
 insert_time timestamp without time zone
);
{% endhighlight %}
Then, we add it to the publication (in this case, I'm creating a new publication, since it's a new cluster in my environment):

{% highlight text %}
java -jar ${XDB_HOME}/bin/edb-repcli.jar -createpub xdbtest -repsvrfile ${XDB_HOME}/etc/xdb_repsvrfile.conf -pubdbid 1 -reptype T -tables public.xdb_lag_test -repgrouptype M -standbyconflictresolution 1:E
{% endhighlight %}

After we verify that replication is working in both directions, create the xdb_lag_history table, trigger and function on the MDN:
{% highlight text %}
CREATE TABLE xdb_lag_history
(
 source_host character varying(50) PRIMARY KEY,
 source_commit timestamp without time zone,
 target_commit timestamp without time zone,
 time_lag text
);

CREATE OR REPLACE FUNCTION update_xdb_lag_history() RETURNS trigger 
AS $$
BEGIN
 IF (TG_OP = 'INSERT') THEN
 INSERT INTO xdb_lag_history VALUES (NEW.source_host, NEW.insert_time, now(), age(now(), NEW.stamp)::text); 
 RETURN NEW;
 END IF;
END
$$ 
LANGUAGE plpgsql VOLATILE;

CREATE TRIGGER target_commit_trigger
 AFTER INSERT ON xdb_lag_test
 FOR EACH ROW
 EXECUTE PROCEDURE update_xdb_lag_history();

ALTER TABLE xdb_lag_test ENABLE ALWAYS TRIGGER target_commit_trigger;
{% endhighlight %}

It is __very important__ to note the `ALTER TABLE` statement that sets `ENABLE ALWAYS TRIGGER` -- this prevents the DML coming from the non-MDN from being ignored by the trigger.  Without this trigger enabled, you'll never get any data inserted into `xdb_lag_history`.
 
Now, `INSERT` a row into `xdb_lag_test` on any of your non-MDNs:
 
{% highlight text %}
edb=# insert into xdb_lag_test values ('non-mdn-1',now());
INSERT 0 1
edb=# select * from xdb_lag_test;
 source_host |        insert_time        
-------------+---------------------------
 non-mdn-1   | 22-AUG-17 23:07:17.168134
(1 row)
{% endhighlight %}
Wait a few seconds for the data to replicate into the MDN, and then go check:
 
{% highlight text %}
edb=# select * from xdb_lag_test ;
 source_host |         insert_time
-------------+---------------------------
 non-mdn-1   | 22-AUG-17 23:07:17.168134
(1 row)

edb=# select * from xdb_lag_history;
 source_host |       source_commit       |       target_commit       |     time_lag      
-------------+---------------------------+---------------------------+-----------------
 non-mdn-1   | 22-AUG-17 23:07:17.168134 | 22-AUG-17 23:07:21.530587 | 00:00:04.362453
(1 row)
{% endhighlight %}

In this system, there was a 4.36sec lag in propagating the `INSERT` statement.  Now, we can write to all the non-MDNs and see how much time it takes for data to replicate into the MDN.  From here, other instrumentation can be to track time lag in EDB Replication Server.
