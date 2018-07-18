---
layout: post
title:  "Making Postgres Talk to LDAP (with StartTLS)"
date:   2018-02-09 13:00:00 -0800
tags: PostgreSQL postgres LDAP authentication SSL StartTLS TLS
comments: true
categories: postgres
---

# Introduction
I recently got a few support cases from customers seeking to connect Postgres with LDAP (usually with some form of SSL/TLS encryption, to ensure security).  I spent a bit of time trying to create a consistently reproducible environment where LDAP could be used to authenticate PostgreSQL connections, and wanted to write it down somewhere.  The trickiest part was to get LDAP + encryption working, and I think I've got a somwhat-reliable way to stand up an environment for testing.

There are a [couple of ways that LDAP implements SSL/TLS encryption](https://forum.forgerock.com/2015/04/ldaps-or-starttls-that-is-the-question/), which we won't get into here, but because Postgres doesn't support LDAPS as of v. 10 (but it [seems like it will be supported in v. 11](https://www.postgresql.org/message-id/E1eWkkK-00083z-1r%40gemulon.postgresql.org)), we will focus on `LDAP + StartTLS`.

# Setting up LDAP
Setting up LDAP seems intimidating, as there's a whole suite of commands and options to explore.  I mean, there are jobs dedicated to this sector of IT Management, not to mention the plethora of different architectures (Active Directory, Kerberos, GSSAPI, PAM, etc.)  Thankfully, [Osixia](http://www.osixia.net/) has made it easy by providing a [docker container](https://github.com/osixia/docker-openldap).  Now, it's a simple as

{% highlight bash %}
docker run --name ldap-service --hostname ldap-service --detach osixia/openldap:1.1.11
{% endhighlight %}

Out of the box, LDAP works.  All you need to do is create an LDAP user, create a counterpart in Postgres with `CREATE ROLE`, and configure `pg_hba.conf` using the [simple bind (not bind+search) method ](https://www.postgresql.org/docs/current/static/auth-methods.html), accordingly:

{% highlight text %}
host   all         all      0.0.0.0/0  ldap ldapserver=ldap-service ldapprefix="cn=" ldapsuffix=", dc=example, dc=org" ldapport=389
{% endhighlight %}

`HUP` the server, sign in with `psql` and all is good:

{% highlight text %}
[root@pg96 /]# PGPASSWORD=foo psql -h 127.0.0.1 -Atc "select 'success'" -U richardyen
psql: FATAL:  LDAP authentication failed for user "richardyen"    ### This failure verifies that the LDAP authentication method was used
[root@pg96 /]# PGPASSWORD=abc123 psql -h 127.0.0.1 -Atc "select 'success'" -U richardyen
success
[root@pg96 /]# 
{% endhighlight %}

# Setting up `LDAP + StartTLS`
It takes a little extra work to make the Docker container behave in a way that Postgres can talk to it with `StartTLS`.  The first step is create your own Certificate Authority, then an SSL certificate and sign it.  Working with SSL/TLS is also intimidating (with all the ciphers, acronyms, versions, and such), and I won't go into that here, but I was surprised to find that [it wasn't terribly hard to get the 3 things that I needed](https://jamielinux.com/docs/openssl-certificate-authority/create-the-root-pair.html).  After that, you need to create your LDAP Docker container by including the `--env LDAP_TLS_VERIFY_CLIENT=try` flag in the `docker run` statement, as mentioned in [Issue #105](https://github.com/osixia/docker-openldap/issues/105#issuecomment-279673189).  Finally, you'll need to copy your CA cert, SSL cert, and SSL key into `/container/service/slapd/assets/`.  Once those are all in place (you may need to do a `docker restart ldap-service`), verify that `LDAP + StartTLS` is working properly by doing a simple `ldapsearch` from the client side (i.e., wherever you're running Postgres):

{% highlight bash %}
[root@pg96 /]# ldapsearch -H "ldap://ldap-service" ldap-service -D "cn=admin,dc=example,dc=org" -b "cn=richardyen,dc=example,dc=org" -Z -LLL -w admin cn
dn: cn=richardyen,dc=example,dc=org
cn: richardyen
{% endhighlight %}

If that's successful, go into your `pg_hba.conf` file and add `ldaptls=1`:

{% highlight text %}
host   all         all      0.0.0.0/0  ldap ldapserver=ldap-service ldapprefix="cn=" ldapsuffix=", dc=example, dc=org" ldaptls=1 ldapport=389
{% endhighlight %}

`HUP` the server, and you should be able to log in with `LDAP + StartTLS` authentication:
{% highlight text %}
$ docker exec -it pg96 psql -Atc "select 'success'" -U richardyen -h 127.0.0.1
Password for user richardyen: 
success
{% endhighlight %}

You can verify that Postgres is indeed using `StartTLS` by inspecting the LDAP server's logs:

{% highlight text %}
$ docker logs ldap-service 2>&1 | tail
5a7ffd6b conn=1013 fd=16 ACCEPT from IP=172.17.0.3:47516 (IP=0.0.0.0:389)
5a7ffd6b conn=1013 op=0 EXT oid=1.3.6.1.4.1.1466.20037
5a7ffd6b conn=1013 op=0 STARTTLS                 ### This line indicates that Postgres was able to connect to the LDAP server with StartTLS ###
5a7ffd6b conn=1013 op=0 RESULT oid= err=0 text=
5a7ffd6b conn=1013 fd=16 TLS established tls_ssf=256 ssf=256
5a7ffd6b conn=1013 op=1 BIND dn="cn=richardyen,dc=example,dc=org" method=128
5a7ffd6b conn=1013 op=1 BIND dn="cn=richardyen,dc=example,dc=org" mech=SIMPLE ssf=0
5a7ffd6b conn=1013 op=1 RESULT tag=97 err=0 text=
5a7ffd6b conn=1013 op=2 UNBIND
5a7ffd6b conn=1013 fd=16 closed
{% endhighlight %}

# Conclusion
Getting PostgreSQL working with LDAP and with SSL/TLS can be intimidating, but it doesn't have to be.  With a bit of poking around on Google, and finding the right resources, what seemed to be a herculian task actually became quite doable.  One important lesson I learned through these support cases, and in setting up this environment, was that it's very important to verify from the client side with `ldapsearch` or `ldapwhoami` with the `-Z` flag to make sure LDAP with encryption was properly set up.  Some people tested only on the LDAP/server side, not on the Postgres side, and lost many hours trying to wrangle with `pg_hba.conf` and ultimately blaming Postgres for being buggy in its implementation of LDAP authentication, when in reality it was LDAP that was misconfigured.
