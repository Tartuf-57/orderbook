-- OrderBook: Step 2 - Functions and stored procedures
-- Run after 01_schema.sql. Run with:  mysql -u root -p < sql/03_routines.sql
USE orderbook;

DROP FUNCTION  IF EXISTS fn_available_cash;
DROP FUNCTION  IF EXISTS fn_available_shares;
DROP PROCEDURE IF EXISTS sp_create_trader;
DROP PROCEDURE IF EXISTS sp_deposit;
DROP PROCEDURE IF EXISTS sp_place_order;
DROP PROCEDURE IF EXISTS sp_execute_trade;
DROP PROCEDURE IF EXISTS sp_cancel_order;
DROP PROCEDURE IF EXISTS sp_reset_demo;

DELIMITER $$

-- ===============================================================
-- Functions
-- ===============================================================
CREATE FUNCTION fn_available_cash(p_trader_id INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v DECIMAL(12,2);
    SELECT cash_balance - reserved_cash INTO v
      FROM traders WHERE trader_id = p_trader_id;
    RETURN IFNULL(v, 0);
END$$

CREATE FUNCTION fn_available_shares(p_trader_id INT, p_stock_id INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v INT;
    SELECT quantity - reserved_qty INTO v
      FROM holdings WHERE trader_id = p_trader_id AND stock_id = p_stock_id;
    RETURN IFNULL(v, 0);
END$$

-- ===============================================================
-- sp_create_trader: returns the new trader_id as a result set
-- ===============================================================
CREATE PROCEDURE sp_create_trader(IN p_name VARCHAR(100), IN p_cash DECIMAL(12,2))
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_name IS NULL OR TRIM(p_name) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Name is required';
    END IF;
    IF p_cash IS NULL OR p_cash < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Starting cash cannot be negative';
    END IF;

    START TRANSACTION;
    INSERT INTO traders (name, cash_balance) VALUES (TRIM(p_name), p_cash);
    SELECT LAST_INSERT_ID() AS trader_id;
    COMMIT;
END$$

-- ===============================================================
-- sp_deposit
-- ===============================================================
CREATE PROCEDURE sp_deposit(IN p_trader_id INT, IN p_amount DECIMAL(12,2))
BEGIN
    DECLARE v_n INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit amount must be positive';
    END IF;

    START TRANSACTION;
    SELECT COUNT(*) INTO v_n FROM traders WHERE trader_id = p_trader_id FOR UPDATE;
    IF v_n = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown trader';
    END IF;

    UPDATE traders SET cash_balance = cash_balance + p_amount
     WHERE trader_id = p_trader_id;
    COMMIT;
END$$

-- ===============================================================
-- sp_place_order: validate, reserve, insert as OPEN, return order_id
-- ===============================================================
CREATE PROCEDURE sp_place_order(
    IN p_trader_id INT,
    IN p_stock_id  INT,
    IN p_side      VARCHAR(4),
    IN p_price     DECIMAL(12,2),
    IN p_quantity  INT)
BEGIN
    DECLARE v_n        INT DEFAULT 0;
    DECLARE v_need     DECIMAL(14,2);
    DECLARE v_order_id INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_side = UPPER(TRIM(IFNULL(p_side, '')));

    IF p_side NOT IN ('BUY', 'SELL') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Side must be BUY or SELL';
    END IF;
    IF p_price IS NULL OR p_price <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Price must be positive';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be positive';
    END IF;

    START TRANSACTION;

    SELECT COUNT(*) INTO v_n FROM stocks WHERE stock_id = p_stock_id;
    IF v_n = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown stock';
    END IF;

    -- lock the trader row
    SELECT COUNT(*) INTO v_n FROM traders WHERE trader_id = p_trader_id FOR UPDATE;
    IF v_n = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown trader';
    END IF;

    IF p_side = 'BUY' THEN
        SET v_need = p_price * p_quantity;
        IF fn_available_cash(p_trader_id) < v_need THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient available cash';
        END IF;
        UPDATE traders SET reserved_cash = reserved_cash + v_need
         WHERE trader_id = p_trader_id;
    ELSE
        -- lock the holding row (if it exists)
        SELECT COUNT(*) INTO v_n FROM holdings
         WHERE trader_id = p_trader_id AND stock_id = p_stock_id FOR UPDATE;
        IF fn_available_shares(p_trader_id, p_stock_id) < p_quantity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient available shares';
        END IF;
        UPDATE holdings SET reserved_qty = reserved_qty + p_quantity
         WHERE trader_id = p_trader_id AND stock_id = p_stock_id;
    END IF;

    INSERT INTO orders (trader_id, stock_id, side, price, quantity)
    VALUES (p_trader_id, p_stock_id, p_side, p_price, p_quantity);
    SET v_order_id = LAST_INSERT_ID();

    COMMIT;
    SELECT v_order_id AS order_id;
END$$

-- ===============================================================
-- sp_execute_trade: one atomic match
-- Lock order: orders (lower id first) -> traders (lower id first)
--             -> holdings (covered by the trader locks)
-- ===============================================================
CREATE PROCEDURE sp_execute_trade(
    IN p_buy_order_id  INT,
    IN p_sell_order_id INT,
    IN p_price         DECIMAL(12,2),
    IN p_quantity      INT)
BEGIN
    DECLARE v_tmp INT;
    DECLARE v_buy_trader  INT;  DECLARE v_sell_trader INT;
    DECLARE v_buy_stock   INT;  DECLARE v_sell_stock  INT;
    DECLARE v_buy_side    VARCHAR(4);  DECLARE v_sell_side VARCHAR(4);
    DECLARE v_buy_price   DECIMAL(12,2);  DECLARE v_sell_price DECIMAL(12,2);
    DECLARE v_buy_qty     INT;  DECLARE v_sell_qty    INT;
    DECLARE v_buy_filled  INT;  DECLARE v_sell_filled INT;
    DECLARE v_buy_status  VARCHAR(10);  DECLARE v_sell_status VARCHAR(10);
    DECLARE v_new_buy_filled  INT;
    DECLARE v_new_sell_filled INT;
    DECLARE v_value       DECIMAL(14,2);
    DECLARE v_trade_id    INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_price IS NULL OR p_price <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trade price must be positive';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trade quantity must be positive';
    END IF;

    START TRANSACTION;

    -- 1. lock the two orders, lower id first
    SELECT order_id INTO v_tmp FROM orders
     WHERE order_id = LEAST(p_buy_order_id, p_sell_order_id) FOR UPDATE;
    SELECT order_id INTO v_tmp FROM orders
     WHERE order_id = GREATEST(p_buy_order_id, p_sell_order_id) FOR UPDATE;

    -- 2. read them
    SELECT trader_id, stock_id, side, price, quantity, filled_qty, status
      INTO v_buy_trader, v_buy_stock, v_buy_side, v_buy_price,
           v_buy_qty, v_buy_filled, v_buy_status
      FROM orders WHERE order_id = p_buy_order_id;

    SELECT trader_id, stock_id, side, price, quantity, filled_qty, status
      INTO v_sell_trader, v_sell_stock, v_sell_side, v_sell_price,
           v_sell_qty, v_sell_filled, v_sell_status
      FROM orders WHERE order_id = p_sell_order_id;

    -- 3. validate
    IF v_buy_trader IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Buy order not found';
    END IF;
    IF v_sell_trader IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sell order not found';
    END IF;
    IF v_buy_side <> 'BUY' OR v_sell_side <> 'SELL' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order sides do not match BUY/SELL';
    END IF;
    IF v_buy_stock <> v_sell_stock THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Orders are for different stocks';
    END IF;
    IF v_buy_trader = v_sell_trader THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Self-trade is not allowed';
    END IF;
    IF v_buy_status NOT IN ('OPEN','PARTIAL') OR v_sell_status NOT IN ('OPEN','PARTIAL') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Both orders must be OPEN or PARTIAL';
    END IF;
    IF p_quantity > (v_buy_qty - v_buy_filled) OR p_quantity > (v_sell_qty - v_sell_filled) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trade quantity exceeds remaining quantity';
    END IF;
    IF p_price > v_buy_price OR p_price < v_sell_price THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trade price is outside the two limit prices';
    END IF;

    -- 4. lock the two traders, lower id first
    SELECT trader_id INTO v_tmp FROM traders
     WHERE trader_id = LEAST(v_buy_trader, v_sell_trader) FOR UPDATE;
    SELECT trader_id INTO v_tmp FROM traders
     WHERE trader_id = GREATEST(v_buy_trader, v_sell_trader) FOR UPDATE;

    SET v_value = p_price * p_quantity;

    -- 5. record the trade
    INSERT INTO trades (stock_id, buy_order_id, sell_order_id, buyer_id, seller_id, price, quantity)
    VALUES (v_buy_stock, p_buy_order_id, p_sell_order_id,
            v_buy_trader, v_sell_trader, p_price, p_quantity);
    SET v_trade_id = LAST_INSERT_ID();

    -- 6. update both orders (status change fires the history trigger)
    SET v_new_buy_filled  = v_buy_filled  + p_quantity;
    SET v_new_sell_filled = v_sell_filled + p_quantity;

    UPDATE orders
       SET filled_qty = v_new_buy_filled,
           status = IF(v_new_buy_filled = v_buy_qty, 'FILLED', 'PARTIAL')
     WHERE order_id = p_buy_order_id;

    UPDATE orders
       SET filled_qty = v_new_sell_filled,
           status = IF(v_new_sell_filled = v_sell_qty, 'FILLED', 'PARTIAL')
     WHERE order_id = p_sell_order_id;

    -- 7. buyer: pay the execution price, release the reservation made at the
    --    LIMIT price. The difference is the price improvement, so it is
    --    refunded automatically (it simply stays in available cash).
    UPDATE traders
       SET cash_balance  = cash_balance  - v_value,
           reserved_cash = reserved_cash - (v_buy_price * p_quantity)
     WHERE trader_id = v_buy_trader;

    -- 8. seller: receive cash
    UPDATE traders SET cash_balance = cash_balance + v_value
     WHERE trader_id = v_sell_trader;

    -- 9. shares move seller -> buyer, seller's reservation is released
    UPDATE holdings
       SET quantity     = quantity     - p_quantity,
           reserved_qty = reserved_qty - p_quantity
     WHERE trader_id = v_sell_trader AND stock_id = v_sell_stock;

    INSERT INTO holdings (trader_id, stock_id, quantity, reserved_qty)
    VALUES (v_buy_trader, v_buy_stock, p_quantity, 0)
    ON DUPLICATE KEY UPDATE quantity = quantity + p_quantity;

    -- 10. last traded price
    UPDATE stocks SET last_price = p_price WHERE stock_id = v_buy_stock;

    COMMIT;
    SELECT v_trade_id AS trade_id;
END$$

-- ===============================================================
-- sp_cancel_order
-- ===============================================================
CREATE PROCEDURE sp_cancel_order(IN p_order_id INT, IN p_trader_id INT)
BEGIN
    DECLARE v_tmp       INT;
    DECLARE v_owner     INT;
    DECLARE v_stock     INT;
    DECLARE v_side      VARCHAR(4);
    DECLARE v_price     DECIMAL(12,2);
    DECLARE v_qty       INT;
    DECLARE v_filled    INT;
    DECLARE v_status    VARCHAR(10);
    DECLARE v_remaining INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT order_id INTO v_tmp FROM orders WHERE order_id = p_order_id FOR UPDATE;

    SELECT trader_id, stock_id, side, price, quantity, filled_qty, status
      INTO v_owner, v_stock, v_side, v_price, v_qty, v_filled, v_status
      FROM orders WHERE order_id = p_order_id;

    IF v_owner IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Order not found';
    END IF;
    IF v_owner <> p_trader_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This order does not belong to you';
    END IF;
    IF v_status NOT IN ('OPEN','PARTIAL') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only OPEN or PARTIAL orders can be cancelled';
    END IF;

    SET v_remaining = v_qty - v_filled;

    SELECT trader_id INTO v_tmp FROM traders WHERE trader_id = v_owner FOR UPDATE;

    IF v_side = 'BUY' THEN
        UPDATE traders SET reserved_cash = reserved_cash - (v_price * v_remaining)
         WHERE trader_id = v_owner;
    ELSE
        UPDATE holdings SET reserved_qty = reserved_qty - v_remaining
         WHERE trader_id = v_owner AND stock_id = v_stock;
    END IF;

    UPDATE orders SET status = 'CANCELLED' WHERE order_id = p_order_id;

    COMMIT;
END$$

-- ===============================================================
-- sp_reset_demo: wipe everything and reload the demo data.
-- Note: ALTER TABLE (to restart the id counters) commits implicitly in MySQL,
-- so the wipe and the reload are two transactions, each all-or-nothing.
-- ===============================================================
CREATE PROCEDURE sp_reset_demo()
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Part 1: wipe (children before parents)
    START TRANSACTION;
    DELETE FROM order_status_history;
    DELETE FROM trades;
    DELETE FROM orders;
    DELETE FROM holdings;
    DELETE FROM traders;
    DELETE FROM stocks;
    COMMIT;

    ALTER TABLE order_status_history AUTO_INCREMENT = 1;
    ALTER TABLE trades               AUTO_INCREMENT = 1;
    ALTER TABLE orders               AUTO_INCREMENT = 1;

    -- Part 2: reload
    START TRANSACTION;

    INSERT INTO stocks (stock_id, symbol, company_name, last_price) VALUES
     (1, 'TCS',      'Tata Consultancy Services', 3900.00),
     (2, 'INFY',     'Infosys',                   1500.00),
     (3, 'RELIANCE', 'Reliance Industries',       2900.00),
     (4, 'HDFCBANK', 'HDFC Bank',                 1650.00),
     (5, 'ITC',      'ITC Limited',                450.00),
     (6, 'WIPRO',    'Wipro',                      500.00);

    INSERT INTO traders (trader_id, name, cash_balance) VALUES
     (1, 'Aarav', 500000.00),
     (2, 'Diya',  300000.00),
     (3, 'Kabir', 200000.00),
     (4, 'Meera', 400000.00),
     (5, 'Rohan', 100000.00);

    INSERT INTO holdings (trader_id, stock_id, quantity) VALUES
     (1, 1,  50), (1, 2, 100),
     (2, 3,  40), (2, 5, 300), (2, 6, 200),
     (3, 4,  60), (3, 1,  30),
     (4, 2,  80), (4, 5, 200), (4, 3,  25),
     (5, 6, 150), (5, 4,  40);

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

    UPDATE traders t
       SET t.reserved_cash = COALESCE((
            SELECT SUM(o.price * (o.quantity - o.filled_qty))
              FROM orders o
             WHERE o.trader_id = t.trader_id AND o.side = 'BUY'
               AND o.status IN ('OPEN','PARTIAL')), 0);

    UPDATE holdings h
       SET h.reserved_qty = COALESCE((
            SELECT SUM(o.quantity - o.filled_qty)
              FROM orders o
             WHERE o.trader_id = h.trader_id AND o.stock_id = h.stock_id
               AND o.side = 'SELL' AND o.status IN ('OPEN','PARTIAL')), 0);

    COMMIT;
END$$

DELIMITER ;
