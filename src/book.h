#pragma once
#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "db.h"

using Money = long long;  // whole paise (no floating point)

inline bool parseMoney(const std::string& s, Money& out) {
    if (s.empty()) return false;
    std::size_t dot = s.find('.');
    std::string w = (dot == std::string::npos) ? s : s.substr(0, dot);
    std::string f = (dot == std::string::npos) ? "" : s.substr(dot + 1);
    if ((w.empty() && f.empty()) || f.size() > 2 || w.size() > 10) return false;
    auto digits = [](const std::string& x) {
        return std::all_of(x.begin(), x.end(), [](unsigned char c) { return std::isdigit(c); });
    };
    if (!digits(w) || !digits(f)) return false;
    long long whole = w.empty() ? 0 : std::stoll(w);
    long long frac  = f.empty() ? 0 : std::stoll(f) * (f.size() == 1 ? 10 : 1);
    out = whole * 100 + frac;
    return true;
}

inline std::string moneyToDecimal(Money m) {
    long long r = std::abs(m) / 100, p = std::abs(m) % 100;
    return (m < 0 ? "-" : "") + std::to_string(r) + "." + (p < 10 ? "0" : "") + std::to_string(p);
}

enum class Side { Buy, Sell };
struct BookOrder { int orderId, traderId; Money price; int remaining; };
struct Fill { Money price; int quantity, restingOrderId; };
struct MatchResult { int orderId = 0, remaining = 0; std::vector<Fill> fills; std::string status, error; };

using SideBook = std::map<Money, std::deque<BookOrder>, std::function<bool(Money, Money)>>;
struct StockBook {
    std::mutex mtx;
    SideBook bids{std::greater<Money>{}}, asks{std::less<Money>{}};
};

class MatchingEngine {
public:
    explicit MatchingEngine(Db& db) : db_(db) {}

    bool reload(std::string& err, int* openCount = nullptr) {
        QueryResult stocks = db_.query("SELECT stock_id FROM stocks ORDER BY stock_id");
        if (!stocks.ok) { err = stocks.err; return false; }
        QueryResult open = db_.query(
            "SELECT order_id, trader_id, stock_id, side, price, quantity - filled_qty "
            "FROM orders WHERE status IN ('OPEN','PARTIAL') ORDER BY created_at, order_id");
        if (!open.ok) { err = open.err; return false; }

        books_.clear();
        for (const auto& row : stocks.rows) books_[std::atoi(row[0].c_str())];
        for (const auto& row : open.rows) {
            auto it = books_.find(std::atoi(row[2].c_str()));
            Money price = 0;
            if (it == books_.end() || !parseMoney(row[4], price)) continue;
            BookOrder o{std::atoi(row[0].c_str()), std::atoi(row[1].c_str()), price, std::atoi(row[5].c_str())};
            (row[3] == "BUY" ? it->second.bids : it->second.asks)[price].push_back(o);
        }
        if (openCount) *openCount = static_cast<int>(open.rows.size());
        return true;
    }

    MatchResult placeOrder(int traderId, int stockId, Side side, Money price, int quantity) {
        MatchResult res;
        auto bookIt = books_.find(stockId);
        if (bookIt == books_.end()) { res.error = "Unknown stock"; return res; }
        std::lock_guard<std::mutex> lock(bookIt->second.mtx);

        DbResult placed = db_.call("CALL sp_place_order(?, ?, ?, ?, ?)",
            {traderId, stockId, side == Side::Buy ? "BUY" : "SELL", moneyToDecimal(price), quantity}, true);
        if (!placed.ok) { res.error = placed.err; return res; }

        res.orderId = placed.id;
        BookOrder inc{res.orderId, traderId, price, quantity};
        SideBook& opp = (side == Side::Buy) ? bookIt->second.asks : bookIt->second.bids;
        SideBook& own = (side == Side::Buy) ? bookIt->second.bids : bookIt->second.asks;

        while (inc.remaining > 0) {
            auto levelIt = opp.begin();
            std::size_t idx = 0;
            bool found = false;
            for (; levelIt != opp.end(); ++levelIt) {
                if (side == Side::Buy ? levelIt->first > inc.price : levelIt->first < inc.price) break;
                for (std::size_t i = 0; i < levelIt->second.size(); ++i)
                    if (levelIt->second[i].traderId != traderId) { idx = i; found = true; break; }
                if (found) break;
            }
            if (!found) break;

            BookOrder& rest = levelIt->second[idx];
            int fill = std::min(inc.remaining, rest.remaining);
            DbResult traded = db_.call("CALL sp_execute_trade(?, ?, ?, ?)",
                {side == Side::Buy ? inc.orderId : rest.orderId,
                 side == Side::Buy ? rest.orderId : inc.orderId,
                 moneyToDecimal(rest.price), fill}, true);
            if (!traded.ok) { res.error = traded.err; break; }

            res.fills.push_back({rest.price, fill, rest.orderId});
            inc.remaining -= fill;
            if ((rest.remaining -= fill) == 0) {
                levelIt->second.erase(levelIt->second.begin() + static_cast<std::ptrdiff_t>(idx));
                if (levelIt->second.empty()) opp.erase(levelIt);
            }
        }
        if (inc.remaining > 0) own[price].push_back(inc);
        res.remaining = inc.remaining;
        res.status = inc.remaining == 0 ? "FILLED" : (inc.remaining == quantity ? "OPEN" : "PARTIAL");
        return res;
    }

    bool cancelOrder(int orderId, int traderId, std::string& err) {
        DbResult r = db_.call("CALL sp_cancel_order(?, ?)", {orderId, traderId});
        if (!r.ok) { err = r.err; return false; }
        for (auto& kv : books_) {
            std::lock_guard<std::mutex> lock(kv.second.mtx);
            if (eraseOrder(kv.second.bids, orderId) || eraseOrder(kv.second.asks, orderId)) break;
        }
        return true;
    }

private:
    static bool eraseOrder(SideBook& levels, int orderId) {
        for (auto it = levels.begin(); it != levels.end(); ++it)
            for (auto q = it->second.begin(); q != it->second.end(); ++q)
                if (q->orderId == orderId) {
                    it->second.erase(q);
                    if (it->second.empty()) levels.erase(it);
                    return true;
                }
        return false;
    }

    Db& db_;
    std::map<int, StockBook> books_;
};
