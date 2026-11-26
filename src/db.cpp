#include "db.h"

#if __has_include(<mysql/jdbc.h>)
#include <mysql/jdbc.h>
#else
#include <mysql_connection.h>
#include <mysql_driver.h>
#include <cppconn/connection.h>
#include <cppconn/driver.h>
#include <cppconn/exception.h>
#include <cppconn/prepared_statement.h>
#include <cppconn/resultset.h>
#endif

#include <cstdlib>
#include <fstream>
#include <utility>

namespace {

struct DbConfig {
    std::string host = "127.0.0.1", user = "root", password, database = "orderbook", socket;
    int port = 3306;
};

std::string trimWs(const std::string& s) {
    std::size_t b = s.find_first_not_of(" \t\r\n");
    return b == std::string::npos ? "" : s.substr(b, s.find_last_not_of(" \t\r\n") - b + 1);
}

DbConfig loadConfig(const std::string& path) {
    DbConfig cfg;
    std::ifstream in(path);
    for (std::string line; std::getline(in, line);) {
        line = trimWs(line);
        std::size_t eq = line.find('=');
        if (line.empty() || line[0] == '#' || eq == std::string::npos) continue;
        std::string k = trimWs(line.substr(0, eq)), v = trimWs(line.substr(eq + 1));
        if      (k == "host")     cfg.host = v;
        else if (k == "port")     cfg.port = std::atoi(v.c_str());
        else if (k == "user")     cfg.user = v;
        else if (k == "password") cfg.password = v;
        else if (k == "database") cfg.database = v;
        else if (k == "socket")   cfg.socket = v;
    }
    if (const char* v = std::getenv("OB_HOST"))     cfg.host = v;
    if (const char* v = std::getenv("OB_USER"))     cfg.user = v;
    if (const char* v = std::getenv("OB_PASSWORD")) cfg.password = v;
    if (const char* v = std::getenv("OB_DB"))       cfg.database = v;
    if (const char* v = std::getenv("OB_SOCKET"))   cfg.socket = v;
    if (const char* v = std::getenv("OB_PORT"))     cfg.port = std::atoi(v);
    return cfg;
}

std::unique_ptr<sql::PreparedStatement> prep(sql::Connection& conn,
                                             const std::string& sqlText,
                                             const std::vector<DbParam>& params) {
    std::unique_ptr<sql::PreparedStatement> ps(conn.prepareStatement(sqlText));
    for (std::size_t i = 0; i < params.size(); ++i) {
        unsigned int idx = static_cast<unsigned int>(i + 1);
        if (params[i].isInt) ps->setInt(idx, params[i].i);
        else                 ps->setString(idx, params[i].s);
    }
    return ps;
}

}  // namespace

Db::Db(std::string configPath) : configPath_(std::move(configPath)) {}
Db::~Db() = default;

bool Db::connect(std::string& err) {
    std::lock_guard<std::mutex> lock(mtx_);
    DbConfig cfg = loadConfig(configPath_);
    try {
        sql::Driver* driver = sql::mysql::get_driver_instance();
        std::string url = cfg.socket.empty()
            ? "tcp://" + cfg.host + ":" + std::to_string(cfg.port)
            : "unix://" + cfg.socket;
        conn_.reset(driver->connect(url, cfg.user, cfg.password));
        conn_->setSchema(cfg.database);
        return true;
    } catch (const sql::SQLException& e) {
        err = std::string("Cannot connect to MySQL: ") + e.what();
        return false;
    }
}

DbResult Db::call(const std::string& sqlText, const std::vector<DbParam>& params, bool readId) {
    std::lock_guard<std::mutex> lock(mtx_);
    DbResult out;
    if (!conn_) { out.err = "Not connected"; return out; }
    try {
        auto ps = prep(*conn_, sqlText, params);
        bool hasResult = ps->execute();
        if (readId && hasResult) {
            std::unique_ptr<sql::ResultSet> rs(ps->getResultSet());
            if (rs->next()) out.id = rs->getInt(1);
        }
        while (ps->getMoreResults()) std::unique_ptr<sql::ResultSet> ignored(ps->getResultSet());
        out.ok = true;
    } catch (const sql::SQLException& e) { out.err = e.what(); }
    return out;
}

QueryResult Db::query(const std::string& sqlText, const std::vector<DbParam>& params) {
    std::lock_guard<std::mutex> lock(mtx_);
    QueryResult out;
    if (!conn_) { out.err = "Not connected"; return out; }
    try {
        auto ps = prep(*conn_, sqlText, params);
        std::unique_ptr<sql::ResultSet> rs(ps->executeQuery());
        sql::ResultSetMetaData* meta = rs->getMetaData();
        unsigned int cols = meta->getColumnCount();
        for (unsigned int c = 1; c <= cols; ++c) out.headers.push_back(std::string(meta->getColumnLabel(c)));
        while (rs->next()) {
            std::vector<std::string> row;
            for (unsigned int c = 1; c <= cols; ++c)
                row.push_back(rs->isNull(c) ? "-" : std::string(rs->getString(c)));
            out.rows.push_back(std::move(row));
        }
        out.ok = true;
    } catch (const sql::SQLException& e) { out.err = e.what(); }
    return out;
}
