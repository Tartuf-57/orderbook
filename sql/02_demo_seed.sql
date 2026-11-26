-- OrderBook: Step 1 - Demo seed
-- 6 stocks, 5 traders, holdings, 15 resting orders.
-- Run after 01_schema.sql. (In Step 2 this same data is reused by sp_reset_demo.)
USE orderbook;

-- Stocks ---------------------------------------------------------
INSERT INTO stocks (stock_id, symbol, company_name, last_price) VALUES
 (1, 'TCS',       'Tata Consultancy Services', 3900.00),
 (2, 'INFY',      'Infosys',                   1500.00),
 (3, 'RELIANCE',  'Reliance Industries',       2900.00),
 (4, 'HDFCBANK',  'HDFC Bank',                 1650.00),
 (5, 'ITC',       'ITC Limited',                450.00),
 (6, 'WIPRO',     'Wipro',                      500.00);

-- Traders (reserved_cash is calculated below from the orders) ----
INSERT INTO traders (trader_id, name, cash_balance) VALUES
 (1, 'Aarav',  500000.00),
 (2, 'Diya',   300000.00),
 (3, 'Kabir',  200000.00),
 (4, 'Meera',  400000.00),
 (5, 'Rohan',  100000.00);

-- Holdings (reserved_qty is calculated below from the orders) ----
INSERT INTO holdings (trader_id, stock_id, quantity) VALUES
 (1, 1,  50),   -- Aarav : TCS
 (1, 2, 100),   --         INFY
 (2, 3,  40),   -- Diya  : RELIANCE
 (2, 5, 300),   --         ITC
 (2, 6, 200),   --         WIPRO
 (3, 4,  60),   -- Kabir : HDFCBANK
 (3, 1,  30),   --         TCS
 (4, 2,  80),   -- Meera : INFY
 (4, 5, 200),   --         ITC
 (4, 3,  25),   --         RELIANCE
 (5, 6, 150),   -- Rohan : WIPRO
 (5, 4,  40);   --         HDFCBANK

-- Resting orders --------------------------------------------------
-- Every stock has best bid < best ask, so nothing matches at start.
-- Inserted one by one so created_at gives a clear time order.
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (1, 5, 'BUY',  445.00, 100);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (1, 6, 'BUY',  495.00, 100);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (2, 1, 'BUY', 3880.00,  10);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (2, 2, 'BUY', 1490.00,  20);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (3, 3, 'BUY', 2880.00,  10);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (3, 5, 'BUY',  440.00, 150);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (4, 4, 'BUY', 1640.00,  20);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (5, 2, 'BUY', 1485.00,  20);

INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (1, 1, 'SELL', 3920.00,  10);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (2, 3, 'SELL', 2920.00,  10);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (3, 4, 'SELL', 1660.00,  20);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (4, 2, 'SELL', 1510.00,  30);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (2, 5, 'SELL',  455.00, 100);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (5, 6, 'SELL',  505.00,  50);
INSERT INTO orders (trader_id, stock_id, side, price, quantity) VALUES (4, 5, 'SELL',  460.00,  50);

-- Reservations: derive from the open orders so they always agree --
UPDATE traders t
SET t.reserved_cash = COALESCE((
    SELECT SUM(o.price * (o.quantity - o.filled_qty))
    FROM orders o
    WHERE o.trader_id = t.trader_id
      AND o.side = 'BUY'
      AND o.status IN ('OPEN','PARTIAL')), 0);

UPDATE holdings h
SET h.reserved_qty = COALESCE((
    SELECT SUM(o.quantity - o.filled_qty)
    FROM orders o
    WHERE o.trader_id = h.trader_id
      AND o.stock_id  = h.stock_id
      AND o.side = 'SELL'
      AND o.status IN ('OPEN','PARTIAL')), 0);
