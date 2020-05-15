---
layout: post
title:  "How to Spot an Impostor: Working with PostgreSQL's SSL Modes"
date:   2020-05-15 13:00:09 -0800
tags: PostgreSQL postgres ssl security
comments: true
categories: postgres
---

# Introduction
Many organizations are prioritizing projects to tighten security around their applications and services after the slew of breaches that made headlines over the past few years.  The use of SSL/TLS has proliferated, and remains an important component to any software deployment.  Unsurprisingly this is true for databases, and the PostgreSQL community is continuing to augment its alraedy-reliable security for the world's most powerful open-source database.

Recently, our team has come across a few customers seeking to implement SSL on their Postgres databases, with a common question that the sought to answer: how come Postgres doesn't reject clients connecting with `sslmode` anything less strict than `verify-ca`?

Understandably, these customers seek to make sure their database connections are watertight and free of any vulnerabilities.  However, there are some parts of the Postgres SSL/TLS implementation that they weren't understanding, and while the whole topic of SSL/TLS and certifcates can be confusing and intimidating, I hope to provide an explanation here for anyone else who hasn't had the courage to ask.

# The Setup
Since there have been hundreds of articles explaining how SSL/TLS works (and a few on how to enable SSL in Postgres), I won't go into that here.  However, to start off, we need to know there are 3 parts of an SSL/TLS implementation:
1. The server (your Postgres database)
1. The client (the `psql` program, your Java app that uses JDBC, your Django app, etc.)
1. The SSL/TLS certificates being passed between the server and client

Once you've set `ssl = on` in your `postgresql.conf`, Postgres will use the certificate and key that have been generated to send encrypted data between itself and its clients.  Note that this has nothing to do with **who** gets to connect to the database.  That's handled by `pg_hba.conf`.  So long as `ssl = on` is set, Postgres **can** (and may or may not, depending on other factors) send/receive encrypted data for a given session.

# What Happens on the Server's Side
When `ssl = on` in `postgresql.conf`, Postgres allows for both SSL and non-SSL connections, depending on what the clients request.  However, some organizations would like Postgres not to allow any non-SSL connections whatsover; this is an understandable requirement, especially for sensitive environments.  To accomplish this, non-SSL connections need to be rejected, and this is done at the authentication phase in `pg_hba.conf`

When a connection comes in, [Postgres will authenticate that connection by scanning through `pg_hba.conf`](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html) to verify that it is allowed to make a connection.  If the connection type, database, user, and IP address all check out, Postgres will then use the specified authentication method (final column) to verify that the human or program that opened the connection has the correct credentials to issue queries and extract data (remember, Postgres will only perform authentication on the first-matched line in `pg_hba.conf`, which basically means, for example, you won't be given a chance to enter a password if your `cert` authentication failed).

The first column in `pg_hba.conf` indicates the method of connection, which can be one of 4 values:
1. `local` -- Local connections coming from the Unix-domain socket
1. `host` -- TCP/IP connections **with or without** requesting SSL encryption
1. `hostssl` -- TCP/IP connections requesting SSL encryption only (Postgres will skip these lines for incoming connections not requesting SSL encryption)
1. `hostnossl` -- TCP/IP connections NOT requesting SSL encryption only (Postgres will skip these lines for incoming connections requesting SSL encryption)

One way to enforce SSL encryption for all TCP/IP-based sessions is by adding a `hostnossl all all all reject` line at the top of your `pg_hba.conf` file.  This will basically reject all non-SSL connections from all IP addresses, thereby enforcing that all non-local sessions to use SSL encryption.

# Using Encrypted sessions
By default, `psql` and most PostgreSQL clients will attempt to connect to PostgreSQL with an SSL connection, and if it encounters some resistance, it will fall back to a non-SSL connection.  The order can be reversed or altered by changing the [`sslmode` parameter](https://www.postgresql.org/docs/current/libpq-connect.html) when creating the connection.  The default value for `sslmode` is `prefer` which, as explained above, attempts SSL first, then attempts non-SSL.  Using a value like `require` will attempt only an SSL connection, and will not subsequently attempt with non-SSL -- it is up to the developer or deployer to set `sslmode` in accordance with the organization's requirements.

To demonstrate, I have configured a server with a `hostnossl all all all reject` at the top of `pg_hba.conf`, and `hostssl all all all password` after it (note that the Linux environment variable `PGSSLMODE` is the way to set `sslmode` for the driver making the connection):
```
[postgres@my-server data]# cat pg_hba.conf 
hostnossl all all all reject
hostssl all all all password
[postgres@my-server data]# PGPASSWORD=testpassword PGSSLMODE=disable psql -h 127.0.0.1 -c "select * from pg_stat_ssl where pid = pg_backend_pid"
psql.bin: FATAL:  pg_hba.conf rejects connection for host "127.0.0.1", user "postgres", database "postgres", SSL off
[postgres@my-server data]# PGPASSWORD=testpassword PGSSLMODE=allow psql -h 127.0.0.1 -c "select * from pg_stat_ssl where pid = pg_backend_pid"
  pid  | ssl | version |           cipher            | bits | compression | clientdn
-------+-----+---------+-----------------------------+------+-------------+----------
 11585 | t   | TLSv1.2 | ECDHE-RSA-AES256-GCM-SHA384 |  256 | f           |
(1 row)

[postgres@my-server data]# PGPASSWORD=testpassword PGSSLMODE=prefer psql -h 127.0.0.1 -c "select * from pg_stat_ssl where pid = pg_backend_pid"
  pid  | ssl | version |           cipher            | bits | compression | clientdn
-------+-----+---------+-----------------------------+------+-------------+----------
 11599 | t   | TLSv1.2 | ECDHE-RSA-AES256-GCM-SHA384 |  256 | f           |
(1 row)

[postgres@my-server data]# PGPASSWORD=testpassword PGSSLMODE=require psql -h 127.0.0.1 -c "select * from pg_stat_ssl where pid = pg_backend_pid"
  pid  | ssl | version |           cipher            | bits | compression | clientdn
-------+-----+---------+-----------------------------+------+-------------+----------
 11606 | t   | TLSv1.2 | ECDHE-RSA-AES256-GCM-SHA384 |  256 | f           |
(1 row)

[postgres@my-server data]# PGPASSWORD=testpassword PGSSLMODE=verify-ca psql -h 127.0.0.1 -c "select * from pg_stat_ssl where pid = pg_backend_pid"
psql.bin: postgres certificate file "/home/postgres/.postgresql/root.crt" does not exist
Either provide the file or change sslmode to disable server certificate verification.
[postgres@my-server data]# PGPASSWORD=testpassword PGSSLMODE=verify-full psql -h 127.0.0.1 -c "select * from pg_stat_ssl where pid = pg_backend_pid"
psql.bin: postgres certificate file "/home/postgres/.postgresql/root.crt" does not exist
Either provide the file or change sslmode to disable server certificate verification.
```
As you can see, when `sslmode` is set to `disabled`, it is rejected because it attempts to connect to the database without SSL encryption, but all other modes will either make a second attempt with SSL encryption turned on, or make an SSL connection on the first try.

# Verifying the Server
The above output leads us to our customers' question: What about `sslmode`s `verify-ca` and `verify-full`?  Why are only these rejected while the other `sslmode` values allowed?  Is Postgres allow non-SSL connections?  Is there a bug in Postgres?  Bear in mind that with the exception of `sslmode=disable`, all connections above are attempting to connect to the database with SSL encryption turned on.  The data flowing on the wire is encrypted.  Sniffers will be unable to read the data on the wire without the certificate.

What then, is the purpose of `sslmode`s `verify-ca` and `verify-full`?  **They are for the _client_ to verify the server.**  The Postgres database authenticates the clients based on their authentication method (password, certificate, LDAP credentials, etc.), but clients like your `psql` program or your Django app cannot verify if the database they have connected to is indeed the database that it claims to be.  After all, what if someone is spoofing a DNS name and masquerading to be a Postgres database when it really is some malicious program stealing credentials?  That's what `verify-ca` and `verify-full` are for.

Recall that when a client (i.e., you) initiates an SSL connection with a server, the server will issue you a certificate with which to encrypt/decrypt all the communication between you two.  You can choose to trust that the server giving you the certificate is indeed the server you wanted to connected to, but if you want to be extra sure, you can take the certificate and verify that it was signed by a third-party Certificate Authority (CA), which requires a good sum of money (enough to prevent me from getting one to demo in this article).  If you as the client verify the certificate to be signed by a CA, you can be almost 100% certain that the server you are talking to is not an impostor (unless, of course, the DBA or sysadmin of that server had lost the corresponding keys to some malicious entity).

# Conclusion
As demonstrated above, with `hostnossl ... reject` at the top of your `pg_hba.conf`, you'll be enforcing all sessions to be opened with SSL encryption enabled.  If you are unsure, wondering whether the data sent across the wire is actually encrypted, and you don't have the wherewithal to spin up a packet sniffer, take a look at `pg_stat_ssl` and see if the `ssl` column is true.  A Postgres database will give its SSL certificate to anyone who asks for it (just like any website will give you its SSL certificate when you visit), but it is up to the client to decide whether to trust that certificate or not (just like your browser will warn you if the website you're visiting is using a self-signed certificate, forcing you to click through with "I know what I'm doing, proceed to website").  Whether the certificate is self-signed or verified by a CA, any `sslmode` besides `disabled` can create an SSL-encrypted session into the Postgres database, thereby keeping your data on the wire safe from sniffers.

Stay safe out there!
