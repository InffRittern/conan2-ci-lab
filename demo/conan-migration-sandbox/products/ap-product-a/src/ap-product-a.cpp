#include <ap-product-a/ap-product-a.h>

#include <ap-sdk/ap-sdk.h>

const char *ap_product_a_product_name() {
    return "ap-product-a";
}

int ap_product_a_product_frame_cost(int width, int height) {
    return ap_sdk_render(width, height);
}
