#include <ap-sdk/ap-sdk.h>

#include <ap-gfx/ap-gfx.h>
#include <ap-box/ap-box.h>

int ap_sdk_render(int width, int height) {
    return ap_gfx_pixels(width, height) + ap_box_api_major();
}

const char *ap_sdk_name() {
    return "ap-sdk";
}
