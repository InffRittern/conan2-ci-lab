import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout


class ApBaseConan(ConanFile):
    name = "ap-base"
    license = "MIT"
    description = "Small foundation library used by the migration sandbox"
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {"shared": [True, False], "fPIC": [True, False]}
    default_options = {"shared": False, "fPIC": True}
    exports_sources = "CMakeLists.txt", "include/*", "src/*"

    def set_version(self):
        self.version = os.getenv("AP_BASE_VERSION", "1.0.0")

    def layout(self):
        cmake_layout(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

    def generate(self):
        deps = CMakeDeps(self)
        deps.generate()
        tc = CMakeToolchain(self)
        tc.variables["AP_BASE_VERSION"] = str(self.version)
        tc.generate()

    def build(self):
        cmake = CMake(self)
        cmake.configure()
        cmake.build()

    def package(self):
        cmake = CMake(self)
        cmake.install()

    def package_info(self):
        self.cpp_info.libs = ["ap-base"]
        self.cpp_info.set_property("cmake_file_name", "ap-base")
        self.cpp_info.set_property("cmake_target_name", "ap-base::ap-base")
