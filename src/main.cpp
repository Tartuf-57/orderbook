#include <cctype>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "book.h"
#include "db.h"
#include "extras.h"

using namespace std;

Db db("orderbook.conf");
MatchingEngine engine(db);
int traderId = 0;
string traderName;

string upper(string s) { for (char& c : s) c = toupper((unsigned char)c); return s; }
string lower(string s) { for (char& c : s) c = tolower((unsigned char)c); return s; }

bool loggedIn() {
    if (traderId == 0) cout << "Please log in first: login <trader_id>\n";
    return traderId != 0;
}

int findStock(const string& symbol) {
    QueryResult r = db.query("SELECT stock_id FROM stocks WHERE symbol = ?", {upper(symbol)});
    if (!r.ok) { cout << "Error: " << r.err << "\n"; return 0; }
    if (r.rows.empty()) { cout << "Unknown symbol. Type 'stocks' to see the list.\n"; return 0; }
    return atoi(r.rows[0][0].c_str());
}

void showQuery(const string& sql, const vector<DbParam>& params = {}, const string& emptyMsg = "") {
    QueryResult r = db.query(sql, params);
    if (!r.ok) { cout << "Error: " << r.err << "\n"; return; }
    if (r.rows.empty() && !emptyMsg.empty()) { cout << emptyMsg << "\n"; return; }
    printTable(r.headers, r.rows);
}

void doRegister(const vector<string>& a) {
    if (a.size() < 2) { cout << "Usage: register <name> <starting_cash>\n"; return; }
    Money cash = 0;
    if (!parseMoney(a.back(), cash)) { cout << "Starting cash must be like 100000 or 25000.50\n"; return; }
    string name;
    for (size_t i = 0; i + 1 < a.size(); i++) name += (i ? " " : "") + a[i];
    DbResult r = db.call("CALL sp_create_trader(?, ?)", {name, moneyToDecimal(cash)}, true);
    if (!r.ok) { cout << "Error: " << r.err << "\n"; return; }
    cout << "Trader created. Your trader id is " << r.id << " (use: login " << r.id << ")\n";
}

void doLogin(const vector<string>& a) {
    if (a.size() != 1) { cout << "Usage: login <trader_id>\n"; return; }
    int id = atoi(a[0].c_str());
    QueryResult r = db.query("SELECT name FROM traders WHERE trader_id = ?", {id});
    if (!r.ok) { cout << "Error: " << r.err << "\n"; return; }
    if (r.rows.empty()) { cout << "No trader with that id. Type 'traders' to see the list.\n"; return; }
    traderId = id;
    traderName = r.rows[0][0];
    cout << "Logged in as " << traderName << ".\n";
}

void doDeposit(const vector<string>& a) {
    if (a.size() != 1) { cout << "Usage: deposit <amount>\n"; return; }
    if (!loggedIn()) return;
    Money amount = 0;
    if (!parseMoney(a[0], amount)) { cout << "Amount must be like 5000 or 5000.50\n"; return; }
    DbResult r = db.call("CALL sp_deposit(?, ?)", {traderId, moneyToDecimal(amount)});
    if (!r.ok) { cout << "Error: " << r.err << "\n"; return; }
    showQuery("SELECT cash_balance AS 'New Balance' FROM traders WHERE trader_id = ?", {traderId});
}

void doTrade(Side side, const vector<string>& a) {
    if (a.size() != 3) { cout << "Usage: buy|sell <symbol> <price> <qty>\n"; return; }
    if (!loggedIn()) return;
    int stockId = findStock(a[0]);
    if (stockId == 0) return;

    Money price = 0;
    if (!parseMoney(a[1], price)) { cout << "Price must be like 450 or 450.50\n"; return; }
    int qty = atoi(a[2].c_str());
    if (qty < 1 || qty > 1000000) { cout << "Quantity must be from 1 to 1000000\n"; return; }

    MatchResult r = engine.placeOrder(traderId, stockId, side, price, qty);
    if (r.orderId == 0) { cout << "Error: " << r.error << "\n"; return; }

    cout << "Order #" << r.orderId << " placed: " << (side == Side::Buy ? "BUY " : "SELL ")
         << qty << " " << upper(a[0]) << " @ " << moneyToDecimal(price) << "\n";
    for (const Fill& f : r.fills)
        cout << "  Traded " << f.quantity << " @ " << moneyToDecimal(f.price)
             << " (with order #" << f.restingOrderId << ")\n";
    cout << (r.remaining > 0 ? "  " + to_string(r.remaining) + " shares waiting in the book (" + r.status + ")\n"
                             : "  Order completely filled.\n");
    if (!r.error.empty()) cout << "  Matching stopped early: " << r.error << "\n";
}

void doBook(const vector<string>& a) {
    if (a.size() != 1) { cout << "Usage: book <symbol>\n"; return; }
    int stockId = findStock(a[0]);
    if (stockId == 0) return;
    cout << "BIDS (buyers)\n";
    showQuery("SELECT price AS Price, CAST(total_qty AS UNSIGNED) AS Qty FROM v_market_depth "
              "WHERE stock_id = ? AND side = 'BUY' ORDER BY price DESC LIMIT 5", {stockId}, "  none");
    cout << "\nASKS (sellers)\n";
    showQuery("SELECT price AS Price, CAST(total_qty AS UNSIGNED) AS Qty FROM v_market_depth "
              "WHERE stock_id = ? AND side = 'SELL' ORDER BY price ASC LIMIT 5", {stockId}, "  none");
}

void doOrders(const vector<string>& a) {
    if (!loggedIn()) return;
    if (!(a.size() == 1 && lower(a[0]) == "all")) {
        showQuery("SELECT order_id AS ID, symbol AS Symbol, side AS Side, price AS Price, "
                  "       quantity AS Qty, filled_qty AS Filled, status AS Status "
                  "FROM v_open_orders WHERE trader_id = ? ORDER BY created_at DESC, order_id DESC LIMIT 10",
                  {traderId}, "No orders to show.");
        return;
    }
    showQuery("SELECT o.order_id AS ID, s.symbol AS Symbol, o.side AS Side, o.price AS Price, "
              "       o.quantity AS Qty, o.filled_qty AS Filled, o.status AS Status "
              "FROM orders o JOIN stocks s ON s.stock_id = o.stock_id WHERE o.trader_id = ? "
              "ORDER BY o.created_at DESC, o.order_id DESC LIMIT 10", {traderId}, "No orders to show.");
}

const char* kHelp = R"(  register <name> <cash>       create a trader
  login <trader_id>            log in
  logout
  deposit <amount>             add cash
  buy <symbol> <price> <qty>   place a buy order
  sell <symbol> <price> <qty>  place a sell order
  cancel <order_id>            cancel one of your orders
  stocks                       all companies and last prices
  traders                      all traders and cash
  recent                       latest orders on the exchange
  book <symbol>                market depth
  orders [all]                 my orders (default: open only)
  history [order_id]           order status change history
  holdings                     my cash and shares
  trades                       my recent trades
  statement                    my account statement
  summary                      trades, volume, high, low per stock
  reset                        wipe everything, reload demo data
  help | exit
)";

int main() {
    string err;
    if (!db.connect(err) || !startupLoad(db, engine, err)) { cout << "Error: " << err << "\n"; return 1; }
    cout << "OrderBook - a small stock exchange simulator. Type 'help' for commands.\n";

    for (string line;;) {
        cout << (traderId ? "orderbook (" + traderName + ")> " : "orderbook> ");
        if (!getline(cin, line)) break;
        istringstream in(line);
        vector<string> words;
        for (string w; in >> w;) words.push_back(w);
        if (words.empty()) continue;

        string cmd = lower(words[0]);
        vector<string> a(words.begin() + 1, words.end());

        if (cmd == "exit" || cmd == "quit") break;
        else if (cmd == "help")      cout << kHelp;
        else if (cmd == "register")  doRegister(a);
        else if (cmd == "login")     doLogin(a);
        else if (cmd == "logout")    { traderId = 0; traderName.clear(); cout << "Logged out.\n"; }
        else if (cmd == "deposit")   doDeposit(a);
        else if (cmd == "buy")       doTrade(Side::Buy, a);
        else if (cmd == "sell")      doTrade(Side::Sell, a);
        else if (cmd == "cancel") {
            if (a.size() != 1) cout << "Usage: cancel <order_id>\n";
            else if (loggedIn()) {
                if (!engine.cancelOrder(atoi(a[0].c_str()), traderId, err)) cout << "Error: " << err << "\n";
                else cout << "Order cancelled.\n";
            }
        }
        else if (cmd == "book")      doBook(a);
        else if (cmd == "orders")    doOrders(a);
        else if (cmd == "history")   showHistory(db, a);
        else if (cmd == "holdings") { if (loggedIn()) {
            showQuery("SELECT cash_balance AS Cash, reserved_cash AS Reserved, cash_balance - reserved_cash AS Available "
                      "FROM traders WHERE trader_id = ?", {traderId});
            cout << "\n";
            showQuery("SELECT s.symbol AS Symbol, h.quantity AS Shares, h.reserved_qty AS Reserved, "
                      "       h.quantity - h.reserved_qty AS Available FROM holdings h JOIN stocks s ON s.stock_id = h.stock_id "
                      "WHERE h.trader_id = ? AND h.quantity > 0 ORDER BY s.symbol", {traderId}, "You hold no shares.");
        }}
        else if (cmd == "trades") { if (loggedIn())
            showQuery("SELECT t.trade_id AS ID, s.symbol AS Symbol, IF(t.buyer_id = ?, 'BUY', 'SELL') AS Side, "
                      "       t.price AS Price, t.quantity AS Qty, t.executed_at AS Time "
                      "FROM trades t JOIN stocks s ON s.stock_id = t.stock_id "
                      "WHERE t.buyer_id = ? OR t.seller_id = ? ORDER BY t.executed_at DESC, t.trade_id DESC LIMIT 10",
                      {traderId, traderId, traderId}, "No trades yet.");
        }
        else if (cmd == "statement") { if (loggedIn()) {
            showQuery("SELECT name AS Name, cash_balance AS Cash, reserved_cash AS Reserved, available_cash AS Available, "
                      "       portfolio_value AS Shares, cash_balance + portfolio_value AS 'Net Worth' "
                      "FROM v_account_statement WHERE trader_id = ? LIMIT 1", {traderId}, "No statement available.");
            cout << "\n";
            showQuery("SELECT symbol AS Symbol, quantity AS Shares, reserved_qty AS Reserved, last_price AS 'Last Price', "
                      "       holding_value AS Value FROM v_account_statement WHERE trader_id = ? AND symbol IS NOT NULL ORDER BY symbol",
                      {traderId}, "You hold no shares.");
        }}
        else if (cmd == "reset") {
            cout << "This wipes ALL data and reloads the demo data. Type yes to continue: ";
            string ans;
            getline(cin, ans);
            if (lower(ans) != "yes") cout << "Reset cancelled.\n";
            else if (DbResult r = db.call("CALL sp_reset_demo()"); !r.ok) cout << "Error: " << r.err << "\n";
            else if (!engine.reload(err)) cout << "Error: " << err << "\n";
            else { traderId = 0; traderName.clear(); cout << "Logged out.\nDemo data restored.\n"; }
        }
        else if (cmd == "stocks")
            showQuery("SELECT symbol AS Symbol, company_name AS Company, last_price AS 'Last Price' FROM stocks ORDER BY stock_id");
        else if (cmd == "traders")
            showQuery("SELECT trader_id AS ID, name AS Name, cash_balance AS Cash FROM traders ORDER BY trader_id");
        else if (cmd == "recent")
            showQuery("SELECT order_id AS ID, trader_name AS Trader, symbol AS Symbol, side AS Side, price AS Price, "
                      "       quantity AS Qty, filled_qty AS Filled, status AS Status FROM v_recent_orders "
                      "ORDER BY created_at DESC, order_id DESC LIMIT 10");
        else if (cmd == "summary")
            showQuery("SELECT symbol AS Symbol, trade_count AS Trades, total_volume AS Volume, high_price AS High, "
                      "       low_price AS Low, last_price AS Last FROM v_trade_summary ORDER BY symbol");
        else
            cout << "Unknown command. Type 'help'.\n";
    }
    cout << "\nGoodbye.\n";
    return 0;
}
