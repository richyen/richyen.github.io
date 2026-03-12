---
layout: post
title:  "Debugging RDS Proxy Pinning: How a Hidden JIT Toggle Created Thousands of Pinned Connections"
date:   2026-03-12 00:00:00 -0800
tags: postgres rds-proxy sqlalchemy asyncpg performance debugging
comments: true
categories: postgres
---

# Introduction

When using AWS RDS Proxy, the goal is to achieve connection multiplexing -- many client connections share a much smaller pool of backend PostgreSQL connections, givng more resources per connection and keeping query execution running smoothly.

However, if the proxy detects that a session has changed internal state in a way it cannot safely track, it **pins** the client connection to a specific backend connection. Once pinned, that connection can never be multiplexed again.  This was the case with a recent database I worked on.

In this case, we observed the following:

- extremely high CPU usage
- relatively high LWLock wait times
- OOM killer activity on the database, maybe once every day or two
- thousands of active connections

What was strange about it all was that the queries involved were relatively simple, with max just one join.

---

# Finding the Pinning Source

To get to the root cause, one option was to look in `pg_stat_statements`.  However, that approach had two problems:

1. Getting a clean snapshot of the statistics while thousands of queries were being actively processed  would be tricky.
2. `pg_stat_statements` normalizes queries and does not expose the values passed to parameter placeholders.

Instead, to see the actual parameters, we briefly enabled `log_statement = 'all'`.  This immediately surfaced something interesting in the logs, which could be downloaded and reviewed on my own time and pace.

What we saw were statements like `SELECT set_config($2,$1,$3)` with parameters related to JIT configuration -- that was the first real clue.

---

# Getting to the Bottom

After tracing the behavior through the stack, the root cause turned out to be surprisingly indirect.  The application created new connections through SQLAlchemy's asyncpg dialect, and we needed to drill down into that driver's behavior.

---

### Step 1 – Reviewing how SQLAlchemy registers JSON codecs

During connection initialization, SQLAlchemy runs an `on_connect` hook:

```python
def connect(conn):
    conn.await_(self.setup_asyncpg_json_codec(conn))
    conn.await_(self.setup_asyncpg_jsonb_codec(conn))
```

This registers optimized JSON and JSONB codecs.

---

### Step 2 – Observing how asyncpg introspects type metadata

Registering those codecs requires looking up type OIDs in `pg_catalog`.

That triggers asyncpg's internal function: `introspect_types()`

---

### Step 3 – Catching asyncpg temporarily disabling JIT

Inside `_introspect_types()` there is this block:

```python
async def _introspect_types(self, typeoids, timeout):
    if self._server_caps.jit:
        cfgrow, _ = await self.__execute(
            """SELECT current_setting('jit') AS cur,
                      set_config('jit', 'off', false) AS new""",
        )
```

The purpose is harmless and avoids rare edge cases with complex type queries by temporarily disabling JIT, running the introspection query, and finally restoring the setting afterwards.  For direct PostgreSQL connections, this is perfectly fine.

Unfortunately, `set_config()` changes session state.  RDS Proxy cannot safely track this change.  So it decides it is necessary to pin the client connection to a backend session.  Once pinned, that connection can never be multiplexed again, for the duration of the session.

In short, since every connection initialization triggers the JIT toggle, every RDS Proxy connection gets pinned to a database connection, effectively invalidating the usefulness of RDS Proxy's purpose of connection multiplexing.  With thousands of live connections doing relatively little, Postmaster develops a lot of LWLock overhead memory buffers don't get flushed, and OOM Killer can be invoked when the conditions are right.

---

# The Fix

The key observation is that asyncpg only runs the JIT toggle if it believes the server supports JIT.

That capability is stored in an internal structure `_server_caps`. If `jit` is set to `False`, asyncpg skips the entire block.

So we added a SQLAlchemy connection hook:

```python
@event.listens_for(engine.sync_engine, "connect", insert=True)
def _prevent_rds_proxy_session_pinning(dbapi_connection, connection_record):
    raw_conn = dbapi_connection._connection
    if hasattr(raw_conn, "_server_caps") and raw_conn._server_caps.jit:
        raw_conn._server_caps = raw_conn._server_caps._replace(jit=False)
```

This configuration does the following:
1. Registers a connection hook so that it runs every time a new connection is created.
2. Runs the hook before SQLAlchemy's own hooks and ensures our handler runs **before** SQLAlchemy's `on_connect` logic.  That is important because the JSON codec registration is what triggers the introspection.
3. Disables the JIT capability flag. By using `_server_caps._replace(jit=False)`, we tell asyncpg to skip the `set_config()` block entirely.


---

# The Result

After deploying the asyncpg fix, we saw the number of pinned sessions drop precipitously:

![RDS Proxy Pinning Graph](https://raw.githubusercontent.com/richyen/richyen.github.io/refs/heads/gh-pages/img/rds_proxy_pinning.png)

Of course, we were still seeing many pinned sessions, which we continued to deal with through other fixes, but this first step produced an improvement of over 50%

---

# Other Fix Attempts That Didn't Work

Before landing on this fix, we attempted a few other approaches.

First, we attempted to disable JIT via connection parameters by setting `server_settings={"jit": "off"}`.  This fails because RDS Proxy rejects it with a message like:

```
FeatureNotSupportedError:
RDS Proxy currently doesn't support the option jit
```

We also tried disabling prepared statement caching with `prepared_statement_cache_size=0` in the configuration.  This didn't work because it prevents named prepared statement pinning, but it does not prevent `set_config()` pinning.

The only fix that worked was to add the pin-prevention hook as described above.

---

# Lessons Learned

A few takeaways from this debugging experience:

1. RDS Proxy pinning can come from unexpected places.  Even small session-level changes can disable multiplexing.
2. `pg_stat_statements` hides parameter values. It's great for query patterns, but it does not expose bound parameters, which can hide critical clues.  Sometimes the fastest diagnostic tool is temporarily enabling `log_statement = 'all'`, which quickly exposed the params in the `set_config()` call.
3. SQLAlchemy and asyncpg do have some quirks that need to be addressed when using them with RDS Proxy

---

# Final Thoughts

The entire chain looked like this:

```
SQLAlchemy connection
 → asyncpg codec registration
 → asyncpg type introspection
 → temporary JIT disable via set_config()
 → RDS Proxy detects session state change
 → connection gets pinned
```

A single hidden configuration toggle resulted in **thousands of pinned sessions**.

Once identified, the fix was only a few lines of code.

But getting there required following the entire stack -- from SQLAlchemy to asyncpg to PostgreSQL to RDS Proxy.

Hopefully this saves someone else a few hours (or days) of debugging.
