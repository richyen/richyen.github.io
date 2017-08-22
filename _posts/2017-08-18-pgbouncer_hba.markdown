---
layout: post
title:  "Using auth_method=hba in PgBouncer"
date:   2017-08-18 13:23:09 -0800
tags: pgbouncer authentication hba
categories: pgbouncer postgres
---

# Introduction
[PgBouncer](https://pgbouncer.github.io/) is a great tool for improving database performance with connection pooling.  I've been using it for many years, since it first became available in 2007.  Since then, several improvements have been implemented, including the ability to use `auth_type=hba`, which implements a PG-like HBA authentication method similar to the `pg_hba.conf` format we're all used to.
 
However, there are a few gotchas that make it a little tricky for new users, and I hope that clarify one of those with this post. For example, using `127.0.0.1` won't work unless the HBA file is set to `0.0.0.0/0`. But if you use the server's IP address (and not the loopback address), it'll work:

{% highlight text %}
[root@mybouncer pgbouncer]# cat bouncer_hba.conf 
host  all  all  172.17.0.0/16 trust
[root@mybouncer pgbouncer]# psql -h 127.0.0.1 -p6432 -c "select 1" prodb enterprisedb
psql: ERROR:  login rejected
[root@mybouncer pgbouncer]# psql -h 172.17.0.4 -p6432 -c "select 1" prodb enterprisedb
 ?column? 
----------
        1
(1 row)
{% endhighlight %}

# Working with the HBA file
Now, if you want to use the server's IP address, the CIDR parsing behaves a bit unexpectedly; in order for bouncer_hba.conf to work as expected, the CIDR notation requires zeros for the masked/irrelevant portions (note that myclient has IP address `172.17.0.5`, but as you'll see, it's not really relevant in the examples I show below):

{% highlight text %}
$ docker exec -it mydb cat /var/lib/edb/as9.6/data/pg_hba.conf
host   all         all      172.1.2.3/8  trust
$ docker exec -it mybouncer cat /etc/pgbouncer/bouncer_hba.conf
host  all  all  172.17.0.4/16 trust
$ docker exec -it myclient psql -h 172.17.0.4 -p6432 -c "select 1" prodb enterprisedb
psql.bin: ERROR:  login rejected
$ docker exec -it mybouncer sed -i "s/0.4/0.0/" /etc/pgbouncer/bouncer_hba.conf
$ docker exec -it mybouncer cat /etc/pgbouncer/bouncer_hba.conf
host  all  all  172.17.0.0/16 trust
$ docker exec -it mybouncer service pgbouncer restart
Restarting pgbouncer:                                      [  OK  ]
$ docker exec -it myclient psql -h 172.17.0.4 -p6432 -c "select 1" prodb enterprisedb
 ?column? 
----------
        1
(1 row)
$ docker exec -it mybouncer sed -i "s/16/8/" /etc/pgbouncer/bouncer_hba.conf
$ docker exec -it mybouncer cat /etc/pgbouncer/bouncer_hba.conf
host  all  all  172.17.0.0/8 trust
$ docker exec -it mybouncer service pgbouncer restart
Restarting pgbouncer:                                      [  OK  ]
$ docker exec -it myclient psql -h 172.17.0.4 -p6432 -c "select 1" prodb enterprisedb
psql.bin: ERROR:  login rejected
$ docker exec -it mybouncer sed -i "s/17.0.0/0.0.0/" /etc/pgbouncer/bouncer_hba.conf
$ docker exec -it mybouncer cat /etc/pgbouncer/bouncer_hba.conf
host  all  all  172.0.0.0/8 trust
$ docker exec -it mybouncer service pgbouncer restart
Restarting pgbouncer:                                      [  OK  ]
$ docker exec -it myclient psql -h 172.17.0.4 -p6432 -c "select 1" prodb enterprisedb
 ?column? 
----------
        1
(1 row)
$ docker exec -it mybouncer sed -i "s/0.0.0/0.0.3/" /etc/pgbouncer/bouncer_hba.conf
$ docker exec -it mybouncer cat /etc/pgbouncer/bouncer_hba.conf
host  all  all  172.0.0.3/8 trust
$ docker exec -it mybouncer service pgbouncer restart
Restarting pgbouncer:                                      [  OK  ]
$ docker exec -it myclient psql -h 172.17.0.4 -p6432 -c "select 1" prodb enterprisedb
psql.bin: ERROR:  login rejected
{% endhighlight %}

# Observations
In most people's experience, if CIDR mask is `/8`, then the last 3 segments of the IPv4 address should be ignored; if mask is `/16`, then the last 2 segments should be ignored--similar for `/24` -- however, it is not actually ignoring them, but requiring them to be set to `0`.  This is just a little gotcha that is easily worked around (as of version 1.7.2).  Hopefully, future releases of PgBouncer will make the HBA parsing behave more like PG's, but for now this works quite well enough.
