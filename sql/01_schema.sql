-- OrderBook: Step 1 - Schema
-- Requires MySQL 8.0.16+ (CHECK constraints are enforced from this version).
-- Safe to re-run: drops and recreates everything.

DROP DATABASE IF EXISTS orderbook;
CREATE DATABASE orderbook CHARACTER SET utf8mb4;
USE orderbook;

-- ---------------------------------------------------------------
-- traders
-- ---------------------------------------------------------------
CREATE TABLE traders (
    trader_id     INT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(100)  NOT NULL,
    cash_balance  DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    reserved_cash DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    created_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_cash_nonneg     CHECK (cash_balance  >= 0),
    CONSTRAINT chk_reserved_nonneg CHECK (reserved_cash >= 0),
    CONSTRAINT chk_reserved_le_cash CHECK (reserved_cash <= cash_balance)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- stocks
-- ---------------------------------------------------------------
CREATE TABLE stocks (
    stock_id     INT AUTO_INCREMENT PRIMARY KEY,
    symbol       VARCHAR(12)  NOT NULL UNIQUE,
    company_name VARCHAR(100) NOT NULL,
    last_price   DECIMAL(12,2) NOT NULL,
    CONSTRAINT chk_last_price_pos CHECK (last_price > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- holdings (one row per trader per stock)
-- ---------------------------------------------------------------
CREATE TABLE holdings (
    trader_id    INT NOT NULL,
    stock_id     INT NOT NULL,
    quantity     INT NOT NULL DEFAULT 0,
    reserved_qty INT NOT NULL DEFAULT 0,
    PRIMARY KEY (trader_id, stock_id),
    CONSTRAINT fk_hold_trader FOREIGN KEY (trader_id) REFERENCES traders(trader_id),
    CONSTRAINT fk_hold_stock  FOREIGN KEY (stock_id)  REFERENCES stocks(stock_id),
    CONSTRAINT chk_qty_nonneg      CHECK (quantity     >= 0),
    CONSTRAINT chk_resqty_nonneg   CHECK (reserved_qty >= 0),
    CONSTRAINT chk_resqty_le_qty   CHECK (reserved_qty <= quantity)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- orders
-- ---------------------------------------------------------------
CREATE TABLE orders (
    order_id   INT AUTO_INCREMENT PRIMARY KEY,
    trader_id  INT NOT NULL,
    stock_id   INT NOT NULL,
    side       ENUM('BUY','SELL') NOT NULL,
    price      DECIMAL(12,2) NOT NULL,
    quantity   INT NOT NULL,                 -- original size
    filled_qty INT NOT NULL DEFAULT 0,
    status     ENUM('OPEN','PARTIAL','FILLED','CANCELLED') NOT NULL DEFAULT 'OPEN',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),  -- time priority
    CONSTRAINT fk_ord_trader FOREIGN KEY (trader_id) REFERENCES traders(trader_id),
    CONSTRAINT fk_ord_stock  FOREIGN KEY (stock_id)  REFERENCES stocks(stock_id),
    CONSTRAINT chk_ord_price_pos   CHECK (price > 0),
    CONSTRAINT chk_ord_qty_pos     CHECK (quantity > 0),
    CONSTRAINT chk_ord_filled_ok   CHECK (filled_qty >= 0 AND filled_qty <= quantity)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- trades
-- ---------------------------------------------------------------
CREATE TABLE trades (
    trade_id      INT AUTO_INCREMENT PRIMARY KEY,
    stock_id      INT NOT NULL,
    buy_order_id  INT NOT NULL,
    sell_order_id INT NOT NULL,
    buyer_id      INT NOT NULL,
    seller_id     INT NOT NULL,
    price         DECIMAL(12,2) NOT NULL,
    quantity      INT NOT NULL,
    executed_at   DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_tr_stock  FOREIGN KEY (stock_id)      REFERENCES stocks(stock_id),
    CONSTRAINT fk_tr_buyo   FOREIGN KEY (buy_order_id)  REFERENCES orders(order_id),
    CONSTRAINT fk_tr_sello  FOREIGN KEY (sell_order_id) REFERENCES orders(order_id),
    CONSTRAINT fk_tr_buyer  FOREIGN KEY (buyer_id)      REFERENCES traders(trader_id),
    CONSTRAINT fk_tr_seller FOREIGN KEY (seller_id)     REFERENCES traders(trader_id),
    CONSTRAINT chk_tr_price_pos CHECK (price > 0),
    CONSTRAINT chk_tr_qty_pos   CHECK (quantity > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- order_status_history (filled by a trigger in Step 2)
-- ---------------------------------------------------------------
CREATE TABLE order_status_history (
    history_id INT AUTO_INCREMENT PRIMARY KEY,
    order_id   INT NOT NULL,
    old_status ENUM('OPEN','PARTIAL','FILLED','CANCELLED') NOT NULL,
    new_status ENUM('OPEN','PARTIAL','FILLED','CANCELLED') NOT NULL,
    changed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    CONSTRAINT fk_hist_order FOREIGN KEY (order_id) REFERENCES orders(order_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------
-- Active-order lookups and order-book depth
CREATE INDEX idx_orders_book
    ON orders (stock_id, side, status, price, created_at);
-- A trader's orders
CREATE INDEX idx_orders_trader
    ON orders (trader_id);
-- Trades by stock and time
CREATE INDEX idx_trades_stock_time
    ON trades (stock_id, executed_at);
