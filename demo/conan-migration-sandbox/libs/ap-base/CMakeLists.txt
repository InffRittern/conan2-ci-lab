cmake_minimum_required(VERSION 3.25)
project(ap-base LANGUAGES CXX)

if(NOT DEFINED AP_BASE_VERSION)
    set(AP_BASE_VERSION "1.0.0")
endif()

add_library(ap-base src/ap-base.cpp)
add_library(ap-base::ap-base ALIAS ap-base)

target_compile_features(ap-base PUBLIC cxx_std_17)
target_compile_definitions(ap-base PRIVATE AP_BASE_VERSION_STRING="${AP_BASE_VERSION}")
target_include_directories(ap-base PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-base EXPORT ap-baseTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-baseTargets NAMESPACE ap-base:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-base)
