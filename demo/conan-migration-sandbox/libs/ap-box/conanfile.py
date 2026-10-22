import os

from conan import ConanFile
from conan.tools.cmake import CMake, CMakeDeps, CMakeToolchain, cmake_layout


class ApBoxConan(ConanFile):
    name = "ap-box"
    license = "MIT"
    description = "Graphics box that pins an external Graphics headers SDK"
    package_type = "library"
    settings = "os", "arch", "compiler", "build_type"
    options = {"shared": [True, False], "fPIC": [True, False]}
    default_options = {"shared": False, "fPIC": True}
    exports_sources = "CMakeLists.txt", "include/*", "src/*"

    def set_version(self):
        self.version = os.getenv("AP_BOX_VERSION", "1.0.0")

    def layout(self):
        cmake_layout(self)

    def config_options(self):
        if self.settings.os == "Windows":
            del self.options.fPIC

    def configure(self):
        if self.options.shared:
            self.options.rm_safe("fPIC")

    def requirements(self):
        # The SDK ships Graphics 1.3 headers and includes them directly.
        # force=True pins that version over ap-texture's [>=1.4 <2]
        # range and keeps this a direct requirement, so CMakeDeps emits its
        # include directories. override=True would drop the include paths in
        # Conan 2.33 because the resulting edge has headers=False.
        self.requires("ap-headers/1.3.290", force=True)
        self.requires("ap-texture/[>=1.0 <2]")

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
        self.cpp_info.libs = ["ap-box"]
        self.cpp_info.set_property("cmake_file_name", "ap-box")
        self.cpp_info.set_property("cmake_target_name", "ap-box::ap-box")
