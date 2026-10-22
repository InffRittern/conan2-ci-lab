#include <cassert>
#include <cstring>

#include <ap-product-a/ap-product-a.h>

int main() {
    assert(std::strcmp(ap_product_a_product_name(), "ap-product-a") == 0);
    assert(ap_product_a_product_frame_cost(2, 3) == 13);
    return 0;
}
