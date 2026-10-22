cmake_minimum_required(VERSION 3.25)
project(ap_gfx_test_package LANGUAGES CXX)

find_package(ap-gfx REQUIRED)

add_executable(test_package test_package.cpp)
target_link_libraries(test_package PRIVATE ap-gfx::ap-gfx)
target_compile_features(test_package PRIVATE cxx_std_17)

enable_testing()
add_test(NAME test_package COMMAND test_package)
