cmake_minimum_required(VERSION 3.25)
project(ap-utils LANGUAGES CXX)

find_package(ap-base REQUIRED)

add_library(ap-utils src/ap-utils.cpp)
add_library(ap-utils::ap-utils ALIAS ap-utils)

target_compile_features(ap-utils PUBLIC cxx_std_17)
target_link_libraries(ap-utils PUBLIC ap-base::ap-base)
target_include_directories(ap-utils PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-utils EXPORT ap-utilsTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-utilsTargets NAMESPACE ap-utils::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-utils)
