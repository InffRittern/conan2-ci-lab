cmake_minimum_required(VERSION 3.25)
project(ap-texture LANGUAGES CXX)

find_package(ap-headers REQUIRED)

add_library(ap-texture src/ap-texture.cpp)
add_library(ap-texture::ap-texture ALIAS ap-texture)

target_compile_features(ap-texture PUBLIC cxx_std_17)
target_link_libraries(ap-texture PUBLIC
    ap-headers::ap-headers)
target_include_directories(ap-texture PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>)

include(GNUInstallDirs)
install(TARGETS ap-texture EXPORT ap-textureTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT ap-textureTargets NAMESPACE ap-texture::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/ap-texture)
