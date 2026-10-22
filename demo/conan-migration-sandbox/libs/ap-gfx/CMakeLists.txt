cmake_minimum_required(VERSION 3.25)
project(ap-gfx LANGUAGES CXX)

find_package(ap-base REQUIRED)
find_package(ap-utils REQUIRED)

add_library(ap-gfx src/ap-gfx.cpp)
add_library(ap-gfx::ap-gfx ALIAS ap-gfx)

target_compile_features(ap-gfx PUBLIC cxx_std_17)
target_link_libraries(ap-gfx PUBLIC ap-base::ap-base ap-utils::ap-utils)
target_include_directories(ap-gfx PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-gfx EXPORT ap-gfxTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-gfxTargets NAMESPACE ap-gfx::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-gfx)
