cmake_minimum_required(VERSION 3.25)
project(ap-sdk LANGUAGES CXX)

find_package(ap-gfx REQUIRED)
find_package(ap-box REQUIRED)

add_library(ap-sdk src/ap-sdk.cpp)
add_library(ap-sdk::ap-sdk ALIAS ap-sdk)

target_compile_features(ap-sdk PUBLIC cxx_std_17)
target_link_libraries(ap-sdk PUBLIC
    ap-gfx::ap-gfx
    ap-box::ap-box)
target_include_directories(ap-sdk PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-sdk EXPORT ap-sdkTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-sdkTargets NAMESPACE ap-sdk::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-sdk)
