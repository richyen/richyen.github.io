---
layout: post
title:  "The Hidden Behavior of plan_cache_mode"
date:   2026-03-30 00:00:00 -0800
tags: PostgreSQL postgres performance query-planner prepared-statements
categories: postgres
---

# Introduction

Most PostgreSQL users use prepared statements as a way to boost performance and prevent SQL injection. Fewer people know that the query planner silently changes the execution plan for prepared statements after exactly five executions.

This behavior often surprises engineers because a query plan can suddenly shift—sometimes dramatically, even though the query itself hasn’t changed. The reason lies in the planner’s handling of custom plans vs generic plans, controlled by the parameter `plan_cache_mode`.

---

# Custom Plans vs Generic Plans

When a prepared statement is executed with parameters, the planner has two choices:

1.  **Custom Plan:** Generated using the actual parameter values. It is potentially optimal for that specific execution but requires planning overhead every time.
2.  **Generic Plan:** Planned once without knowing specific parameter values. It is reused for all subsequent executions to save planning overhead.

By default, `plan_cache_mode` is set to `auto`. In this mode, the planner uses custom plans for the first five executions. On the `sixth` execution, it compares the average cost of those custom plans against the estimated cost of a generic plan. If the generic plan is deemed "cheaper" or equal, the planner switches to it permanently for that session.

---

# Demonstrating with pgbench

As always, `pgbench` is the schema of choice when it comes to simple demonstrations.  I'm using Postgres 18, which is the latest version as of this writing.  Adding a column with highly skewed values makes it easier to trigger the switch, for the purposes of this post.  Therefore we add a `flag` column with extreme skew: `'N'` for 0.1% of rows, `'Y'` for the remaining 99.9%:

```bash
### In bash:
pgbench -i -s 10 -U postgres postgres

### In psql:
ALTER TABLE pgbench_accounts ADD COLUMN flag CHAR(1) NOT NULL DEFAULT 'Y';
UPDATE pgbench_accounts SET flag = 'N' WHERE aid <= 1000;
CREATE INDEX idx_accounts_flag ON pgbench_accounts(flag);
ANALYZE pgbench_accounts;

SELECT flag, count(*) FROM pgbench_accounts GROUP BY flag;

 flag | count
------+--------
 N    |   1000
 Y    | 999000
```

Before triggering the auto-switch, let's force each mode directly to see what the planner produces for the same statement.

```sql
-- Custom plan: planner sees the literal value 'Y', looks it up in column
-- statistics (MCV frequency ≈ 0.999), and picks Seq Scan for 999,033 rows.
SET plan_cache_mode = force_custom_plan;
PREPARE flag_lookup(char) AS
  SELECT aid, abalance FROM pgbench_accounts WHERE flag = $1;

EXPLAIN EXECUTE flag_lookup('Y');
```
```
                               QUERY PLAN
-------------------------------------------------------------------------
 Seq Scan on pgbench_accounts  (cost=0.00..28910.00 rows=999033 width=8)
   Filter: (flag = 'Y'::bpchar)   <-- literal value 'Y' indicates custom plan
```

```sql
DEALLOCATE flag_lookup;

-- Generic plan: the planner has no value to look up. With ndistinct = 2
-- (only 'Y' and 'N' exist), it estimates 1/ndistinct = 50% selectivity,
-- or 500,000 rows. At that estimate, the cheaper path is Index Scan.
SET plan_cache_mode = force_generic_plan;
PREPARE flag_lookup(char) AS
  SELECT aid, abalance FROM pgbench_accounts WHERE flag = $1;

EXPLAIN EXECUTE flag_lookup('Y');
```
```
                                            QUERY PLAN
--------------------------------------------------------------------------------------------
 Index Scan using idx_accounts_flag on pgbench_accounts  (cost=0.42..19322.07 rows=500000)
   Index Cond: (flag = $1)   <-- Note the placeholder $1 instead of literal 'Y'/'N'
```

The cost numbers reveal the selection of Index Scan over Seq Scan: 19,322 < 28,910.

# The Automatic Switch in Action

After resetting `plan_cache_mode` back to `auto`, we execute the statement five times using the common value `'Y'`. Each run generates a custom Seq Scan plan at cost ~28,910. After five such executions, the planner compares `Average custom plan cost: ~28,910` v. `Generic plan cost: ~19,322`

Since 19,322 ≤ 28,910, the generic plan is chosen from execution 6 onward.

```sql
DEALLOCATE flag_lookup;
SET plan_cache_mode = auto;
PREPARE flag_lookup(char) AS
  SELECT aid, abalance FROM pgbench_accounts WHERE flag = $1;

-- Executions 1–5: custom plans, each resolving 'Y' literally
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');
```
Each shows:
```
           QUERY PLAN
--------------------------------
 Seq Scan on pgbench_accounts
   Filter: (flag = 'Y'::bpchar)
```

On the sixth execution:
```
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');
                       QUERY PLAN
--------------------------------------------------------
 Index Scan using idx_accounts_flag on pgbench_accounts
   Index Cond: (flag = $1)
```

The strategy flips from Seq Scan to Index Scan on the sixth call — even though the query and data are identical. The `$1` placeholder confirms the generic plan is now used.

# Does it Ever Switch Back?

From execution 6 onward, every query — regardless of the parameter value — uses that generic Index Scan. For `'N'` (1,000 rows) an Index Scan happens to be efficient. For `'Y'` (999,000 rows), scanning nearly the entire 1M-row table through random index lookups is dramatically worse than a sequential scan would be.

```sql
-- Executions 7+: generic plan regardless of value
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('Y');  -- 999,000 rows via Index Scan (bad!)
EXPLAIN (COSTS OFF) EXECUTE flag_lookup('N');  -- 1,000 rows via Index Scan (fine by accident)
```
Both show:
```
                       QUERY PLAN
--------------------------------------------------------
 Index Scan using idx_accounts_flag on pgbench_accounts
   Index Cond: (flag = $1)
```

The generic plan stays until `DEALLOCATE flag_lookup` or the session ends.  This is certainly something to be aware of for frequently-executed prepared statements, as it has had significant consequences on usability with some customers I've worked with.

---

# Under the Hood: The C Logic

Just to highlight that the number 5 isn't determined with any fancy logic, we can find it in the source code. In `src/backend/utils/cache/plancache.c` (around **line 1200**), the function `choose_custom_plan` spells it out explicitly:

```c
static bool
choose_custom_plan(CachedPlanSource *plansource)
{
    /* ... settings check for force_custom / force_generic ... */

    /* If we haven't done 5 custom plans yet, keep doing them */
    if (plansource->num_custom_plans < 5)
        return true;

    /* * Otherwise, compare generic_cost against the average custom_cost.
     * If the generic plan is cheaper (or equal), we switch!
     */
    if (plansource->generic_cost <= plansource->total_custom_cost / plansource->num_custom_plans)
        return false;

    return true;
}

```

---

# Final Thoughts

The query planner's automatic plan caching is usually a hero, saving CPU cycles. But when you have highly skewed data or volatile temporary objects, that "6th run switch" can negatively affect client/application performance.

If you see unexplained regressions in a prepared statement, you may want to check to see if it is being called more than 5 times, or try `SET plan_cache_mode = force_custom_plan` as a troubleshooting step.  This forces a fresh custom plan on every execution, guaranteeing the planner always sees the actual parameter value and can choose the right strategy.

Good luck!
