-- OrderBook: Step 2 - Triggers
USE orderbook;

DROP TRIGGER IF EXISTS trg_orders_bu;
DROP TRIGGER IF EXISTS trg_orders_au;
DROP TRIGGER IF EXISTS trg_trades_bi;

DELIMITER $$

-- Block invalid changes to an order
CREATE TRIGGER trg_orders_bu
BEFORE UPDATE ON orders
FOR EACH ROW
BEGIN
    -- a FILLED or CANCELLED order is frozen
    IF OLD.status IN ('FILLED','CANCELLED')
       AND (NEW.status <> OLD.status OR NEW.filled_qty <> OLD.filled_qty) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A FILLED or CANCELLED order cannot be changed';
    END IF;

    -- an order can never go back to OPEN
    IF NEW.status <> OLD.status AND NEW.status = 'OPEN' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Invalid status change';
    END IF;
END$$

-- Record every status change
CREATE TRIGGER trg_orders_au
AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        INSERT INTO order_status_history (order_id, old_status, new_status)
        VALUES (NEW.order_id, OLD.status, NEW.status);
    END IF;
END$$

-- No trade between a trader and themselves
CREATE TRIGGER trg_trades_bi
BEFORE INSERT ON trades
FOR EACH ROW
BEGIN
    IF NEW.buyer_id = NEW.seller_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Buyer and seller cannot be the same trader';
    END IF;
END$$

DELIMITER ;
