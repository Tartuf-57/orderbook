# Tests

## 1. Scenario tests

`scenarios.txt` holds the scenarios. `run_tests.sh` plays each one against the real
program and checks the output.

```
cd ~/orderbook
bash tests/run_tests.sh              # all scenarios
bash tests/run_tests.sh partial      # only scenarios with "partial" in the name
```

**Warning:** every scenario starts with `reset`, so running the tests wipes the
database back to the demo data.

| # | Scenario | What it proves |
|---|----------|----------------|
| 01 | Full fill | Exact match trades at the resting price; cash and shares move |
| 02 | Partial fill | Matched part trades, the rest waits as PARTIAL and shows in `book` |
| 03 | No match | Order rests as OPEN, no trade happens |
| 04 | Price improvement | Buyer bids 3950, pays 3920, the difference is not charged |
| 05 | Cancel | Reservation is released; cancelling twice is rejected |
| 06 | Rejected orders | Insufficient cash/shares, bad price, bad quantity, unknown symbol; nothing is saved |
| 07 | Self-trade | A trader's bid is not matched with their own ask |
| 08 | Restart recovery | Program is closed and reopened; the order book is rebuilt from MySQL |
| 09 | Reset | Trades, new traders and new orders disappear; demo data returns |
| 10 | Bad input | Garbage commands give a friendly message, never a crash |

Reading `scenarios.txt`: the `--- input` lines are what is typed into the program,
and the `--- expect` lines must appear in its output (repeated spaces are ignored).
`!text` means the text must not appear, `@2 text` means it must appear in the second
session (`---SESSION---` closes and reopens the program).

Database-level checks (invalid price/quantity rejected inside MySQL, rollbacks,
triggers) are in `sql/06_test_step2.sql`.

## 2. Index comparison (EXPLAIN)

```
sudo mysql < sql/07_explain_index.sql
```

The script runs four queries with the composite indexes, drops them, runs the same
four queries again, then restores the indexes. For each EXPLAIN, note the `key`
(index used), `rows` (rows MySQL expects to read) and `Extra` (look for
`Using filesort` and `Using index`).

| Query | WITH composite index: key / rows / Extra | WITHOUT: key / rows / Extra |
|-------|------------------------------------------|-----------------------------|
| Q1 open BUY orders for a stock | *(fill in from your run)* | *(fill in)* |
| Q2a my recent trades | *(fill in)* | *(fill in)* |
| Q2b recent trades of one stock | *(fill in)* | *(fill in)* |
| Q3 market depth (view) | *(fill in)* | *(fill in)* |

What to expect, so you know what to look for (this is the theory, not a result):

* **Q1 and Q3** can use `idx_orders_book` (stock, side, status, price, created_at). Without it
  they fall back to the plain `stock_id` index and have to filter and sort the rows.
* **Q2b** can use `idx_trades_stock_time` to read trades already sorted by time, avoiding a filesort.
* **Q2a** filters on buyer and seller, so it uses the foreign-key indexes on those columns either
  way. Expect little or no difference between the two runs; say so in the report.

### Honest note for the report

The demo data is tiny (about 20 orders and a couple of trades), so all of it fits in a
page or two. MySQL knows a full scan is just as cheap, so it may ignore the index
even when it exists, and there is no measurable difference in run time. The composite
index only pays off on large data, where it lets MySQL jump straight to one
stock/side/price range already in sorted order instead of reading and sorting every
order. EXPLAIN shows the plan the optimizer chose; it does not prove a speed-up at this
data size.
