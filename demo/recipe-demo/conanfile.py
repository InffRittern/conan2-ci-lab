from conan import ConanFile
from conan.tools.files import copy
import os


class RecipeDemoConan(ConanFile):
    name = "recipe-demo"
    version = "1.0.0"
    package_type = "header-library"
    license = "MIT"
    author = "Conan migration lab"
    url = "https://gitea.example.com/packages/recipe-demo"
    description = "Minimal recipe repository used to verify Conan migration"
    topics = ("conan", "migration", "header-only")

    exports_sources = "include/*"
    no_copy_source = True

    def package_id(self):
        # Header-only package: one binary independent of settings.
        self.info.clear()

    def package(self):
        copy(
            self,
            "*.h",
            src=os.path.join(self.source_folder, "include"),
            dst=os.path.join(self.package_folder, "include"),
        )

    def package_info(self):
        self.cpp_info.includedirs = ["include"]
