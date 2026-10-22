#include <ap-headers/ap-headers.h>

#ifndef AP_HEADERS_VERSION_STRING
#define AP_HEADERS_VERSION_STRING "1.4.1"
#endif

const char *ap_headers_version() {
    return AP_HEADERS_VERSION_STRING;
}

int ap_headers_major() {
    return AP_HEADERS_VERSION_STRING[0] - '0';
}
