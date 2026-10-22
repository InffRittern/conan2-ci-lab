import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout


class ApGfxConan(ConanFile):
    name = "ap-gfx"
    license = "MIT"
    description = "Graphics primitives built on ap-base and ap-utils"
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {"shared": [True, False], "fPIC": [True, False]}
    default_options = {"shared": False, "fPIC": True}
    exports_sources = "CMakeLists.txt", "include/*", "src/*"

    def set_version(self):
        self.version = os.getenv("AP_GFX_VERSION", "1.0.0")

    def layout(self):
        cmake_layout(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

    def requirements(self):
        self.requires("ap-base/[>=1.0 <2]")
        self.requires("ap-utils/[>=1.0 <2]")

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
        self.cpp_info.libs = ["ap-gfx"]
        self.cpp_info.set_property("cmake_file_name", "ap-gfx")
        self.cpp_info.set_property("cmake_target_name", "ap-gfx::ap-gfx")
