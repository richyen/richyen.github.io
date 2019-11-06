---
layout: post
title:  "Making Mystery-Solving Easier with auto_explain"
date:   2019-11-06 13:00:09 -0800
tags: PostgreSQL postgres performance explain auto_explain
comments: true
categories: postgres
---

# Introduction
I recently had to work on a case where a customer noticed some poor application performance after migrating from Oracle to PostgreSQL.  They seemed to have tried everything in the playbook, but the problem simply wouldn't get any better.  They tried tuning autovacuum (but the tables weren't bloated), tried tuning `shared_buffers` (but `EXPLAIN ANALYZE` wasn't showing stuff getting pulled from heap), tried swapping JDBC drivers (but both EDB and Community PgJDBC drivers had the same performance) -- in short, they poked around just about everywhere they could think of, but couldn't make the queries run any faster.  They were very convinced that the cause of the slowness was due to some waiting required after inserting/updating rows in the database; we removed the replica and had the application work with just one database, but the statistics didn't change--it was still slower than expected.

# Getting Past the Smoke
The first step we took in resolving this issue was to log all durations, just in case anything was missed.  We set `log_min_duration_statement = 0` and set off the test sequence.  What came back was interesting (after some `sed`, `grep`, and `sort`ing):
```
 Duration     Statement
------------+-------------------------------
 828.950 ms   execute <unnamed>: UPDATE ...
 829.322 ms   execute <unnamed>: UPDATE ...
 830.615 ms   execute <unnamed>: UPDATE ...
 831.923 ms   execute <unnamed>: UPDATE ...
 832.499 ms   execute <unnamed>: UPDATE ...
 833.595 ms   execute <unnamed>: UPDATE ...
 836.353 ms   execute <unnamed>: UPDATE ...
 863.769 ms   execute <unnamed>: UPDATE ...
```

That proved to me the bottleneck wasn't some `INSERT`-delay, but that a particular `UPDATE` on one table was consuming about 4.5 minutes of testing time (there were ~270 instances of these `UPDATE`s).  Easy enough--just figure out why the `UPDATE` was taking so long, right?  Not so fast.  On a table with ~3M rows, only a sequential scan would make it take ~800ms to do an `UPDATE` on a `WHERE` clause based on two indexed integer columns.  I took one of those `UPDATE`s in the log and ran it through `EXPLAIN ANALYZE` -- sure enough, it used an Index Scan.  Odd.  Maybe it was a caching issue?  Or maybe it had something to do with custom/generic plan selection for prepared statements?  We tried it:
```
BEGIN;
PREPARE foo AS UPDATE customer_table SET col1 = $1, col2 = $2, col3 = $3 WHERE col4 = $4 AND col5 = $5;
EXPLAIN ANALYZE EXECUTE foo('string1', 'string2', 'string3', 'string4', 123, 456);
ROLLBACK;
```

Again, Index Scan.  This wass getting serious--why would such a basic `WHERE` clause lead to a Sequential Scan when it yielded an Index Scan when run manually?

# Trapping the Culprit
We had the customer set up `auto_explain`.  It's an excellent tool for situations like this--when there seems to be a ghost in the machine, or at least some funny smell.  In `postgresql.conf`:
```
shared_preload_libraries = 'auto_explain'
auto_explain.log_min_duration = 0
auto_explain.log_analyze = on
```

The result:
```
####-##-## ##:##:## EST [#####]: [###-#] [xid=######] user=###,db=###,appEnterpriseDB JDBC Driver,client=### LOG:  00000: duration: 889.074 ms  plan:
    Query Text: UPDATE customer_table SET col1 = $1, col2 = $2, col3 = $3 WHERE col4 = $4 AND col5 = $5
    Update on customer_table  (cost=0.00..89304.06 rows=83 width=1364) (actual time=889.070..889.070 rows=0 loops=1)
      ->  Seq Scan on customer_table  (cost=0.00..89304.06 rows=83 width=1364) (actual time=847.736..850.867 rows=1 loops=1)
            Filter: (((col4)::double precision = '123'::double precision) AND ((col5)::double precision = '456'::double precision))
            Rows Removed by Filter: 3336167
```

At first glance, it didn't seem like there was anything wrong with this `EXPLAIN ANALYZE` output (except for the performance), but after getting some additional eyes and thoughts, it became clear that the four casts to `double precision` was the cause.  If we tinker with `pgbench` a little, we can see:
```
postgres=# EXPLAIN ANALYZE SELECT filler FROM pgbench_accounts WHERE aid = 1 AND bid = 1;
                                                               QUERY PLAN                                                                
-----------------------------------------------------------------------------------------------------------------------------------------
 Index Scan using pgbench_accounts_pkey on pgbench_accounts  (cost=0.29..8.31 rows=1 width=85) (actual time=0.058..0.078 rows=1 loops=1)
   Index Cond: (aid = 1)
   Filter: (bid = 1)
 Planning time: 0.575 ms
 Execution time: 0.303 ms
(5 rows)

postgres=# EXPLAIN ANALYZE SELECT filler FROM pgbench_accounts WHERE aid::double precision = 1::double precision AND bid::double precision = 1::double precision;
                                                     QUERY PLAN                                                      
---------------------------------------------------------------------------------------------------------------------
 Seq Scan on pgbench_accounts  (cost=0.00..3640.00 rows=2 width=85) (actual time=0.028..17.608 rows=1 loops=1)
   Filter: (((aid)::double precision = '1'::double precision) AND ((bid)::double precision = '1'::double precision))
   Rows Removed by Filter: 99999
 Planning time: 0.137 ms
 Execution time: 17.790 ms
(5 rows)
```

# Unmasking the Villain
So who's casting the `int`s to `double`s?  Fingers first pointed at JDBC, but after the customer's code revealed that a `Connection` object was doing an `executeUpdate()` instead of a `Statement` or `PreparedStatement` object, I set off to Google and found that the customer's third-party interface was adding an `executeUpdate()` method for database connections.  That `Connection.executeUpdate()` method was iterating through the parameter list and storing them into a `PreparedStatement` object using `setObject()`.  There was no additional logic being performed to use any alternate methods, like `setInt()` or `setString()`.  `setObject()` basically converted all the `int` arguments into `double precision`, and tricked the query planner into thinking that an additional cast was needed.

# Conclusion
Having `auto_explain` was very helpful in this situation, as it gave us visibility into what exactly got passed around in the database, and how the query planner interpreted all the incoming queries.  Without it, we'd be left scratching our heads, wondering why we couldn't get an index scan even though an index was available.  After all, who would've had the notion that integers were inadvertently getting re-cast into doubles?  With `auto_explain` and some keen eyes, that task of tracking down the Bad Guys becomes much easier.
