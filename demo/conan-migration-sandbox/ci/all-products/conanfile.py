from conan import ConanFile


class AllProductsConan(ConanFile):
    """Graph-only root used by the product release pipeline.

    Resolving one root that requires every final product gives a single
    consistent graph for all products.  The package is never published; it
    exists so Conan can detect version/option conflicts before any product is
    promoted to ``develop``.
    """

    name = "ap-all-products"
    version = "1.0.0"
    package_type = "application"
    settings = "os", "arch", "compiler", "build_type"

    def requirements(self):
        self.requires("ap-product-a/[>=1.0 <2]")
        self.requires("ap-product-b/[>=1.0 <2]")
