cmake_minimum_required(VERSION 3.25)
project(ap-headers LANGUAGES CXX)

if(NOT DEFINED AP_HEADERS_VERSION)
    set(AP_HEADERS_VERSION "1.4.1")
endif()

add_library(ap-headers src/ap-headers.cpp)
add_library(ap-headers::ap-headers ALIAS ap-headers)

target_compile_features(ap-headers PUBLIC cxx_std_17)
target_compile_definitions(ap-headers PRIVATE
    AP_HEADERS_VERSION_STRING="${AP_HEADERS_VERSION}")
target_include_directories(ap-headers PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-headers EXPORT ap-headersTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-headersTargets NAMESPACE ap-headers::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-headers)
