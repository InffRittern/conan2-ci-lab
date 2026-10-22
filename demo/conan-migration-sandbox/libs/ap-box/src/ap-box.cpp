#include <ap-box/ap-box.h>

#include <ap-texture/ap-texture.h>
#include <ap-headers/ap-headers.h>

const char *ap_box_backend() {
    return "graphics";
}

int ap_box_api_major() {
    return ap_headers_major();
}
