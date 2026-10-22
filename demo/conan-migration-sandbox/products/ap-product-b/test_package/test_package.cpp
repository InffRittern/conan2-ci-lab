#include <cassert>
#include <cstring>

#include <ap-product-b/ap-product-b.h>

int main() {
    assert(std::strcmp(ap_product_b_product_name(), "ap-product-b") == 0);
    assert(ap_product_b_product_score(1) == 8);
    return 0;
}
