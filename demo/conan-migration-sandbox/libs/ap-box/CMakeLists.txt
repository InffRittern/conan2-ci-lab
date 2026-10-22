cmake_minimum_required(VERSION 3.25)
project(ap-box LANGUAGES CXX)

find_package(ap-headers REQUIRED)
find_package(ap-texture REQUIRED)

add_library(ap-box src/ap-box.cpp)
add_library(ap-box::ap-box ALIAS ap-box)

target_compile_features(ap-box PUBLIC cxx_std_17)
target_link_libraries(ap-box PUBLIC
    ap-headers::ap-headers
    ap-texture::ap-texture)
target_include_directories(ap-box PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-box EXPORT ap-boxTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-boxTargets NAMESPACE ap-box::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-box)
