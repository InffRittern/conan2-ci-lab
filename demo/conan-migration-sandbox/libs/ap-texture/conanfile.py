import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout


class ApTextureConan(ConanFile):
    name = "ap-texture"
    license = "MIT"
    description = "Texture format helper requiring modern Graphics headers"
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {"shared": [True, False], "fPIC": [True, False]}
    default_options = {"shared": False, "fPIC": True}
    exports_sources = "CMakeLists.txt", "include/*", "src/*"

    def set_version(self):
        self.version = os.getenv("AP_TEXTURE_VERSION", "1.0.0")

    def layout(self):
        cmake_layout(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

    def requirements(self):
        self.requires("ap-headers/[>=1.4 <2]")

    def generate(self):
        CMakeDeps(self).generate()
        CMakeToolchain(self).generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["ap-texture"]
        self.cpp_info.set_property("cmake_file_name", "ap-texture")
        self.cpp_info.set_property(
            "cmake_target_name", "ap-texture::ap-texture")
