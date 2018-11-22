---
layout: post
title:  "PgBouncer Pro Tip: Use auth_user"
date:   2018-11-21 15:00:00 -0800
tags: pgbouncer authentication hba postgres PostgreSQL
comments: true
categories: pgbouncer postgres
---

# Introduction
Anyone running a database in a production environment with over a hundred users should seriously consider employing a connection pooler to keep resource usage under control.  [PgBouncer](https://pgbouncer.github.io/) is one such tool, and it's great because it's lightweight and yet has a handful of nifty features for DBAs that have very specific needs.
 
One of these nifty features that I want to share about is the `auth_user` and `auth_query` combo that serves as an alternative to the default authentication process that uses `userlist.txt`  "What's wrong with `userlist.txt`" you may ask.  For starters, it makes user/role administration a little tricky.  Every time you add a new user to PG, you need to add it to `userlist.txt` in PgBouncer.  And every time you change a password, you have to change it in `userlist.txt` as well.  Multiply that by the 30+ servers you're managing, and you've got a sysadmin's nightmare on your hands.  With `auth_user` and `auth_query`, you can centralize the password management and take one item off your checklist.

# What's `auth_user`?
In the `[databases]` section of your `pgbouncer.ini`, you would typically specify a `user=` and `password=` with which PgBouncer will connect to the Postgres database with.  If left blank, the user/password are declared at the connection string (i.e., `psql -U <username> <database>`).  When this happens, PgBouncer will perform a lookup of the provided username/password against `userlist.txt` to verify that the credentials are correct, and then the username/password are sent to Postgres for an actual database login.

When `auth_user` is provided, PgBouncer will still read in credentials from the connection string, but instead of comparing against `userlist.txt`, it logs in to Postgres with the specified `auth_user` (preferably a non-superuser) and runs `auth_query` to pull the corresponding md5 password hash for the desired user.  The validation is performed at this point, and if correct, the specified user is allowed to log in.

# An Example
Assuming Postgres is installed and running, you can get the `auth_user` and `auth_query` combo running with the following steps:

1. Create a Postgres user to use as `auth_user`
1. Create the user/password lookup function in Postgres
1. Configure `pgbouncer.ini`

## Create a Postgres user to use as `auth_user`
In your terminal, run `psql -c "CREATE ROLE myauthuser WITH PASSWORD 'abc123'"` to create `myauthuser`.  Note that `myauthuser` should be an unprivileged user, wiht no `GRANT`s to read/write any tables.  `myauthuser` is used strictly for assisting with PgBouncer authentication.

For the purposes of this example, we'll also have a database user called `mydbuser`, which can be created with:
{% highlight text %}
CREATE ROLE mydbuser WITH PASSWORD 'mysecretpassword'
GRANT SELECT ON emp TO mydbuser;
{% endhighlight %}

## Create the user/password lookup function in Postgres
In your `psql` prompt, create a function that will be used by `myauthuser` to perform the user/password lookup:

{% highlight text %}
CREATE OR REPLACE FUNCTION user_search(uname TEXT) RETURNS TABLE (usename name, passwd text) as
$$
  SELECT usename, passwd FROM pg_shadow WHERE usename=$1;
$$
LANGUAGE sql SECURITY DEFINER;
{% endhighlight %}

As mentioned in the [documentation](https://pgbouncer.github.io/config.html), the `SECURITY DEFINER` clause enables the non-privileged `myauthuser` to view the contents of `pg_shadow`, which would otherwise be limited to only admin users.

## Configure `pgbouncer.ini`
Configure your `[databases]` section with an alias, like:

{% highlight text %}
[databases]
foodb = host=db1 dbname=edb auth_user=myauthuser
{% endhighlight %}

Then, configure `auth_query` in the `[pgbouncer]` section with:
{% highlight text %}
auth_query = SELECT usename, passwd FROM user_search($1)
{% endhighlight %}

## Let 'er rip!
Spin up PgBouncer and try logging in:
{% highlight text %}
PGPASSWORD=thewrongpassword psql -h 127.0.0.1 -p 6432 -U mydbuser -Atc 'SELECT '\''success'\''' foodb
psql: ERROR:  Auth failed
PGPASSWORD=mysecretpassword psql -h 127.0.0.1 -p 6432 -U mydbuser -Atc 'SELECT '\''success'\''' foodb
success
{% endhighlight %}

As you can see, providing the wrong password for `mydbuser` led to a `pg_shadow` lookup failure, and the user was prevented from logging in.  The subsequent `psql` call used the correct password, and successfully logged in.

# Some Caveats
I've seen a few customers try to implement this, and one of the common mistakes I've seen is the failure to set `pg_hba.conf` properly in Postgres.  Bear in mind that once the provided credentials are validated, PgBouncer will attempt to log in with the specified user.  Therefore, if your `auth_user` is `myauthuser` and you've got a `pg_hba.conf` with `host all myauthuser 127.0.0.1/32 md5`, but you want to ultimately login with `mydbuser`, you won't be able to do so because there's no `pg_hba.conf` entry for `mydbuser`, and you'll probably see something like this:

{% highlight text %}
server login failed: FATAL no pg_hba.conf entry for host "127.0.0.1", user "mydbuser", database "edb", SSL off
{% endhighlight %}

Also, make sure `auth_type` is not set to `trust` in `pgbouncer.ini` -- instead, you should set `trust` in `pg_hba.conf` for `auth_user` and clamp it down to only the IP(s) that will be running PgBouncer.  Set `auth_type` to `md5` so that your login attempt will be challenged with a password request.

Enjoy!
