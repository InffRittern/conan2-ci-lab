#include <ap-product-b/ap-product-b.h>

#include <ap-base/ap-base.h>
#include <ap-sdk/ap-sdk.h>

const char *ap_product_b_product_name() {
    return "ap-product-b";
}

int ap_product_b_product_score(int seed) {
    return ap_sdk_render(seed, seed + 1) + ap_base_add(seed, 2);
}
