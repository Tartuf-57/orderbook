-- OrderBook: Step 2 - Direct SQL tests
-- Run with --force so the script keeps going after the expected errors:
--   mysql -u root -p --force < sql/06_test_step2.sql
-- Order ids are predictable because sp_reset_demo restarts the counters:
--   1-8 are the demo BUY orders, 9-15 are the demo SELL orders
--   (9 = Aarav SELL TCS 3920, 13 = Diya SELL ITC 455 x100, 15 = Meera SELL ITC 460).
USE orderbook;

CALL sp_reset_demo();

-- ---------------------------------------------------------------
-- Test A: full fill with price improvement
-- Kabir (3) bids 3950 for 10 TCS; resting ask is Aarav's 3920 (order 9).
-- ---------------------------------------------------------------
SELECT '--- A: full fill + price improvement' AS test;
CALL sp_place_order(3, 1, 'BUY', 3950.00, 10);          -- order 16
CALL sp_execute_trade(16, 9, 3920.00, 10);

SELECT trader_id, name, cash_balance, reserved_cash FROM traders WHERE trader_id IN (1,3);
-- EXPECT  Aarav 539200.00 / 94000.00     Kabir 160800.00 / 94800.00
--         (Kabir reserved 39500 at his limit, released 39500, paid only 39200)
SELECT trader_id, stock_id, quantity, reserved_qty FROM holdings
 WHERE stock_id = 1 AND trader_id IN (1,3);
-- EXPECT  Aarav TCS 40 / 0     Kabir TCS 40 / 0
SELECT order_id, status, filled_qty FROM orders WHERE order_id IN (9,16);
-- EXPECT  both FILLED, filled_qty 10
SELECT symbol, last_price FROM stocks WHERE stock_id = 1;
-- EXPECT  TCS 3920.00

-- ---------------------------------------------------------------
-- Test B: partial fill
-- Rohan (5) buys 40 ITC at 455; Diya's ask (order 13) has 100.
-- ---------------------------------------------------------------
SELECT '--- B: partial fill' AS test;
CALL sp_place_order(5, 5, 'BUY', 455.00, 40);           -- order 17
CALL sp_execute_trade(17, 13, 455.00, 40);

SELECT order_id, status, filled_qty, quantity FROM orders WHERE order_id IN (13,17);
-- EXPECT  13 PARTIAL 40/100     17 FILLED 40/40
SELECT trader_id, stock_id, quantity, reserved_qty FROM holdings
 WHERE stock_id = 5 AND trader_id IN (2,5);
-- EXPECT  Diya ITC 260 / 60     Rohan ITC 40 / 0

-- ---------------------------------------------------------------
-- Test C: cancel releases the reservation
-- ---------------------------------------------------------------
SELECT '--- C: cancel' AS test;
CALL sp_cancel_order(13, 2);

SELECT order_id, status FROM orders WHERE order_id = 13;
-- EXPECT  CANCELLED
SELECT trader_id, quantity, reserved_qty FROM holdings WHERE trader_id = 2 AND stock_id = 5;
-- EXPECT  Diya ITC 260 / 0
SELECT order_id, old_status, new_status FROM order_status_history WHERE order_id = 13 ORDER BY history_id;
-- EXPECT  OPEN->PARTIAL, PARTIAL->CANCELLED

-- ---------------------------------------------------------------
-- Test D: rejected orders (each CALL should print an error)
-- ---------------------------------------------------------------
SELECT '--- D: rejections' AS test;
CALL sp_place_order(5, 1, 'BUY',  3900.00, 1000);   -- Insufficient available cash
CALL sp_place_order(5, 1, 'SELL', 3900.00, 1);      -- Insufficient available shares
CALL sp_place_order(5, 1, 'BUY',  -1.00,   10);     -- Price must be positive
CALL sp_place_order(5, 1, 'BUY',  100.00,  0);      -- Quantity must be positive
CALL sp_place_order(5, 1, 'HOLD', 100.00,  1);      -- Side must be BUY or SELL

-- ---------------------------------------------------------------
-- Test E: self-trade, wrong-owner cancel, frozen order
-- ---------------------------------------------------------------
SELECT '--- E: self-trade and protection' AS test;
CALL sp_place_order(4, 5, 'BUY', 470.00, 10);       -- Meera, order 18
CALL sp_execute_trade(18, 15, 460.00, 10);          -- Self-trade is not allowed
CALL sp_cancel_order(18, 1);                        -- This order does not belong to you
CALL sp_cancel_order(18, 4);                        -- OK
SELECT trader_id, reserved_cash FROM traders WHERE trader_id = 4;
-- EXPECT  Meera 32800.00 (back to the demo value)
CALL sp_cancel_order(18, 4);                        -- Only OPEN or PARTIAL orders can be cancelled
UPDATE orders SET status = 'OPEN' WHERE order_id = 9;  -- A FILLED or CANCELLED order cannot be changed

-- ---------------------------------------------------------------
-- Test F: views
-- ---------------------------------------------------------------
SELECT '--- F: views' AS test;
SELECT * FROM v_market_depth WHERE symbol = 'ITC' ORDER BY side, price;
SELECT * FROM v_trade_summary;
SELECT * FROM v_account_statement WHERE trader_id = 3;
SELECT * FROM v_recent_orders LIMIT 5;
SELECT * FROM v_open_orders LIMIT 5;

-- ---------------------------------------------------------------
-- Test G: reset returns to demo state
-- ---------------------------------------------------------------
SELECT '--- G: reset' AS test;
CALL sp_reset_demo();
SELECT (SELECT COUNT(*) FROM stocks) AS stocks, (SELECT COUNT(*) FROM traders) AS traders,
       (SELECT COUNT(*) FROM orders) AS orders, (SELECT COUNT(*) FROM trades) AS trades;
-- EXPECT  6, 5, 15, 0
