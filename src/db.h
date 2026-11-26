#pragma once
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace sql { class Connection; }

struct DbParam {
    bool isInt = false;
    int i = 0;
    std::string s;
    DbParam(int v) : isInt(true), i(v) {}
    DbParam(std::string v) : s(std::move(v)) {}
    DbParam(const char* v) : s(v ? v : "") {}
};

struct DbResult { bool ok = false; int id = 0; std::string err; };

struct QueryResult {
    bool ok = false;
    std::vector<std::string> headers;
    std::vector<std::vector<std::string>> rows;
    std::string err;
};

class Db {
public:
    explicit Db(std::string configPath = "orderbook.conf");
    ~Db();
    bool connect(std::string& err);
    DbResult call(const std::string& sqlText, const std::vector<DbParam>& params = {}, bool readId = false);
    QueryResult query(const std::string& sqlText, const std::vector<DbParam>& params = {});
private:
    std::string configPath_;
    std::mutex mtx_;
    std::unique_ptr<sql::Connection> conn_;
};
