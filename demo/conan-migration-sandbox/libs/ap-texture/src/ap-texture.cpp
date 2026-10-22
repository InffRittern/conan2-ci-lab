#include <ap-texture/ap-texture.h>

#include <ap-headers/ap-headers.h>

const char *ap_texture_format() {
    return "AP_FORMAT_RGBA8_UNORM";
}

bool ap_texture_supported() {
    return ap_headers_major() >= 1;
}
