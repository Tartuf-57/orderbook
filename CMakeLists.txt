cmake_minimum_required(VERSION 3.10)
project(OrderBook CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- MySQL Connector/C++ (the classic "JDBC-style" API) ---
# On Ubuntu/WSL:  sudo apt install libmysqlcppconn-dev
# Newer versions ship mysql/jdbc.h, the legacy 1.1.x version ships mysql_driver.h.
# db.cpp handles both.
find_path(MYSQLCPPCONN_INCLUDE_DIR
          NAMES mysql/jdbc.h mysql_driver.h
          PATH_SUFFIXES mysql-cppconn-8 mysql-cppconn)
find_library(MYSQLCPPCONN_LIB NAMES mysqlcppconn)

if(NOT MYSQLCPPCONN_INCLUDE_DIR OR NOT MYSQLCPPCONN_LIB)
    message(FATAL_ERROR
        "MySQL Connector/C++ not found. On Ubuntu/WSL run: "
        "sudo apt install libmysqlcppconn-dev")
endif()

find_package(Threads REQUIRED)

file(GLOB ORDERBOOK_SOURCES ${CMAKE_SOURCE_DIR}/src/*.cpp)

add_executable(orderbook ${ORDERBOOK_SOURCES})
target_include_directories(orderbook PRIVATE ${MYSQLCPPCONN_INCLUDE_DIR})
target_link_libraries(orderbook PRIVATE ${MYSQLCPPCONN_LIB} Threads::Threads)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(orderbook PRIVATE -Wall -Wextra)
endif()
