-- OrderBook: Step 6 - Index comparison with EXPLAIN
--
-- Runs the key queries with the indexes, drops the composite indexes,
-- runs the same queries again, then puts everything back.
-- Read the "key", "rows" and "Extra" columns of each EXPLAIN.
--
-- Run (it resets the demo data first):
--   sudo mysql < sql/07_explain_index.sql
--
-- Note: the data here is tiny (about 20 orders), so MySQL may choose a full
-- scan even when an index exists. See the honest note at the end.

USE orderbook;

-- A clean starting point plus a few real trades so `trades` is not empty.
CALL sp_reset_demo();
CALL sp_place_order(3, 1, 'BUY', 3950.00, 10);    -- order 16
CALL sp_execute_trade(16, 9, 3920.00, 10);
CALL sp_place_order(5, 5, 'BUY', 455.00, 40);     -- order 17
CALL sp_execute_trade(17, 13, 455.00, 40);
ANALYZE TABLE orders, trades;

-- ===============================================================
-- PART 1: WITH the composite indexes (as created in 01_schema.sql)
-- ===============================================================
SELECT '=== PART 1: WITH idx_orders_book and idx_trades_stock_time ===' AS section;
SHOW INDEX FROM orders;
SHOW INDEX FROM trades;

SELECT 'Q1 open BUY orders for one stock (matching engine / order book)' AS query_name;
EXPLAIN SELECT order_id, price, quantity - filled_qty AS remaining, created_at
        FROM orders
        WHERE stock_id = 5 AND side = 'BUY' AND status IN ('OPEN','PARTIAL')
        ORDER BY price DESC, created_at;

SELECT 'Q2a my recent trades (trader 3)' AS query_name;
EXPLAIN SELECT trade_id, stock_id, price, quantity, executed_at
        FROM trades
        WHERE buyer_id = 3 OR seller_id = 3
        ORDER BY executed_at DESC LIMIT 10;

SELECT 'Q2b recent trades of one stock' AS query_name;
EXPLAIN SELECT trade_id, price, quantity, executed_at
        FROM trades
        WHERE stock_id = 5
        ORDER BY executed_at DESC LIMIT 10;

SELECT 'Q3 market depth for one stock (view)' AS query_name;
EXPLAIN SELECT * FROM v_market_depth WHERE stock_id = 5;

-- ===============================================================
-- PART 2: WITHOUT the composite indexes
-- MySQL needs SOME index on stock_id for the foreign keys, so a plain
-- single-column index is added before the composite one is dropped.
-- ===============================================================
ALTER TABLE orders ADD INDEX idx_orders_stock_only (stock_id);
ALTER TABLE orders DROP INDEX idx_orders_book;
ALTER TABLE trades ADD INDEX idx_trades_stock_only (stock_id);
ALTER TABLE trades DROP INDEX idx_trades_stock_time;
ANALYZE TABLE orders, trades;

SELECT '=== PART 2: WITHOUT the composite indexes (plain stock_id index only) ===' AS section;
SHOW INDEX FROM orders;
SHOW INDEX FROM trades;

SELECT 'Q1 open BUY orders for one stock (matching engine / order book)' AS query_name;
EXPLAIN SELECT order_id, price, quantity - filled_qty AS remaining, created_at
        FROM orders
        WHERE stock_id = 5 AND side = 'BUY' AND status IN ('OPEN','PARTIAL')
        ORDER BY price DESC, created_at;

SELECT 'Q2a my recent trades (trader 3)' AS query_name;
EXPLAIN SELECT trade_id, stock_id, price, quantity, executed_at
        FROM trades
        WHERE buyer_id = 3 OR seller_id = 3
        ORDER BY executed_at DESC LIMIT 10;

SELECT 'Q2b recent trades of one stock' AS query_name;
EXPLAIN SELECT trade_id, price, quantity, executed_at
        FROM trades
        WHERE stock_id = 5
        ORDER BY executed_at DESC LIMIT 10;

SELECT 'Q3 market depth for one stock (view)' AS query_name;
EXPLAIN SELECT * FROM v_market_depth WHERE stock_id = 5;

-- ===============================================================
-- PART 3: put the schema back exactly as it was
-- ===============================================================
ALTER TABLE orders ADD INDEX idx_orders_book (stock_id, side, status, price, created_at);
ALTER TABLE orders DROP INDEX idx_orders_stock_only;
ALTER TABLE trades ADD INDEX idx_trades_stock_time (stock_id, executed_at);
ALTER TABLE trades DROP INDEX idx_trades_stock_only;
ANALYZE TABLE orders, trades;

SELECT '=== PART 3: indexes restored ===' AS section;
SHOW INDEX FROM orders;
SHOW INDEX FROM trades;

-- ---------------------------------------------------------------
-- Honest note for the report:
-- With roughly 20 orders and 2 trades, every table fits in one or two
-- pages. The optimizer knows a full scan is just as cheap, so it may
-- ignore the composite index, and measured run time is the same either
-- way. The index only pays off on large data: it lets MySQL jump straight
-- to one stock/side/price range already in sorted order, instead of
-- reading and sorting every order. The EXPLAIN output shows the plan
-- the optimizer chose (key, rows, Extra); it does not prove a speed gain
-- on this data size.
-- ---------------------------------------------------------------
