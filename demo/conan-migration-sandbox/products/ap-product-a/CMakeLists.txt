cmake_minimum_required(VERSION 3.25)
project(ap-product-a LANGUAGES CXX)

find_package(ap-sdk REQUIRED)

add_library(ap-product-a src/ap-product-a.cpp)
add_library(ap-product-a::ap-product-a ALIAS ap-product-a)

target_compile_features(ap-product-a PUBLIC cxx_std_17)
target_link_libraries(ap-product-a PUBLIC ap-sdk::ap-sdk)
target_include_directories(ap-product-a PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-product-a EXPORT ap-product-aTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-product-aTargets NAMESPACE ap-product-a::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-product-a)
