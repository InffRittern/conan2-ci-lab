cmake_minimum_required(VERSION 3.25)
project(ap-product-b LANGUAGES CXX)

find_package(ap-sdk REQUIRED)
find_package(ap-base REQUIRED)

add_library(ap-product-b src/ap-product-b.cpp)
add_library(ap-product-b::ap-product-b ALIAS ap-product-b)

target_compile_features(ap-product-b PUBLIC cxx_std_17)
target_link_libraries(ap-product-b PUBLIC ap-sdk::ap-sdk ap-base::ap-base)
target_include_directories(ap-product-b PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-product-b EXPORT ap-product-bTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-product-bTargets NAMESPACE ap-product-b::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-product-b)
