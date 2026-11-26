#pragma once
#include <algorithm>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "book.h"
#include "db.h"

inline void printTable(const std::vector<std::string>& headers,
                       const std::vector<std::vector<std::string>>& rows) {
    std::vector<std::size_t> w;
    for (const std::string& h : headers) w.push_back(h.size());
    for (const auto& row : rows)
        for (std::size_t c = 0; c < row.size(); ++c) w[c] = std::max(w[c], row[c].size());
    for (std::size_t c = 0; c < headers.size(); ++c) std::cout << std::left << std::setw(static_cast<int>(w[c] + 2)) << headers[c];
    std::cout << "\n";
    for (const auto& row : rows) {
        for (std::size_t c = 0; c < row.size(); ++c) std::cout << std::left << std::setw(static_cast<int>(w[c] + 2)) << row[c];
        std::cout << "\n";
    }
}

inline bool startupLoad(Db& db, MatchingEngine& engine, std::string& err) {
    bool accOk = false;
    std::string accErr;
    int traders = 0, orders = 0;

    std::thread t([&] {
        QueryResult r = db.query("SELECT COUNT(*) FROM traders");
        if (!r.ok) { accErr = r.err; return; }
        if (!r.rows.empty()) traders = std::atoi(r.rows[0][0].c_str());
        accOk = true;
    });
    bool bookOk = engine.reload(err, &orders);
    t.join();

    if (!bookOk) return false;
    if (!accOk) { err = accErr; return false; }
    std::cout << "Loaded " << orders << " open orders and " << traders << " trader accounts.\n";
    return true;
}

inline void showHistory(Db& db, const std::vector<std::string>& args) {
    std::string sql =
        "SELECT h.history_id AS ID, h.order_id AS `Order`, s.symbol AS Symbol, "
        "       h.old_status AS `From`, h.new_status AS `To`, h.changed_at AS Time "
        "FROM order_status_history h JOIN orders o ON o.order_id = h.order_id "
        "JOIN stocks s ON s.stock_id = o.stock_id ";
    QueryResult r = args.empty()
        ? db.query(sql + "ORDER BY h.history_id DESC LIMIT 15")
        : db.query(sql + "WHERE h.order_id = ? ORDER BY h.history_id ASC", {std::atoi(args[0].c_str())});
    if (!r.ok) { std::cout << "Error: " << r.err << "\n"; return; }
    if (r.rows.empty()) { std::cout << "No status history yet.\n"; return; }
    printTable(r.headers, r.rows);
}
