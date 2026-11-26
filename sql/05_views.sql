-- OrderBook: Step 2 - Views
USE orderbook;

-- Open and partial orders (JOIN)
CREATE OR REPLACE VIEW v_open_orders AS
SELECT o.order_id, o.trader_id, t.name AS trader_name,
       o.stock_id, s.symbol, o.side, o.price,
       o.quantity, o.filled_qty,
       (o.quantity - o.filled_qty) AS remaining_qty,
       o.status, o.created_at
FROM orders o
JOIN traders t ON t.trader_id = o.trader_id
JOIN stocks  s ON s.stock_id  = o.stock_id
WHERE o.status IN ('OPEN','PARTIAL');

-- Market depth: same-price orders combined (JOIN + GROUP BY)
CREATE OR REPLACE VIEW v_market_depth AS
SELECT s.stock_id, s.symbol, o.side, o.price,
       SUM(o.quantity - o.filled_qty) AS total_qty,
       COUNT(*)                       AS order_count
FROM orders o
JOIN stocks s ON s.stock_id = o.stock_id
WHERE o.status IN ('OPEN','PARTIAL')
GROUP BY s.stock_id, s.symbol, o.side, o.price;

-- Account statement: one row per trader per holding
-- (JOIN + correlated subquery for the portfolio total)
CREATE OR REPLACE VIEW v_account_statement AS
SELECT t.trader_id, t.name,
       t.cash_balance, t.reserved_cash,
       (t.cash_balance - t.reserved_cash) AS available_cash,
       s.symbol, h.quantity, h.reserved_qty,
       s.last_price,
       (h.quantity * s.last_price) AS holding_value,
       (SELECT COALESCE(SUM(h2.quantity * s2.last_price), 0)
          FROM holdings h2
          JOIN stocks s2 ON s2.stock_id = h2.stock_id
         WHERE h2.trader_id = t.trader_id) AS portfolio_value
FROM traders t
LEFT JOIN holdings h ON h.trader_id = t.trader_id AND h.quantity > 0
LEFT JOIN stocks   s ON s.stock_id  = h.stock_id;

-- Trade summary per stock (derived-table subquery + GROUP BY + JOIN)
CREATE OR REPLACE VIEW v_trade_summary AS
SELECT s.stock_id, s.symbol, s.company_name,
       COALESCE(x.trade_count, 0)  AS trade_count,
       COALESCE(x.total_volume, 0) AS total_volume,
       x.high_price, x.low_price,
       s.last_price
FROM stocks s
LEFT JOIN (
    SELECT stock_id,
           COUNT(*)      AS trade_count,
           SUM(quantity) AS total_volume,
           MAX(price)    AS high_price,
           MIN(price)    AS low_price
    FROM trades
    GROUP BY stock_id
) x ON x.stock_id = s.stock_id;

-- All orders, newest first
CREATE OR REPLACE VIEW v_recent_orders AS
SELECT o.order_id, t.name AS trader_name, s.symbol, o.side,
       o.price, o.quantity, o.filled_qty, o.status, o.created_at
FROM orders o
JOIN traders t ON t.trader_id = o.trader_id
JOIN stocks  s ON s.stock_id  = o.stock_id
ORDER BY o.created_at DESC, o.order_id DESC;
