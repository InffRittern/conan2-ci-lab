#include <ap-base/ap-base.h>

#ifndef AP_BASE_VERSION_STRING
#define AP_BASE_VERSION_STRING "1.0.0"
#endif

int ap_base_add(int a, int b, int c) {
    return a + b + c;
}

int ap_base_multiply(int a, int b) {
    return a * b;
}

const char *ap_base_version() {
    return AP_BASE_VERSION_STRING;
}
