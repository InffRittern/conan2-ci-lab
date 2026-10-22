cmake_minimum_required(VERSION 3.25)
project(ap_box_test_package LANGUAGES CXX)

find_package(ap-box REQUIRED)

add_executable(test_package test_package.cpp)
target_link_libraries(test_package PRIVATE ap-box::ap-box)
target_compile_features(test_package PRIVATE cxx_std_17)

enable_testing()
add_test(NAME test_package COMMAND test_package)
