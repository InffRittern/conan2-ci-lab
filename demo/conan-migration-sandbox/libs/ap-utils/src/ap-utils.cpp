#include <ap-utils/ap-utils.h>

#include <ap-base/ap-base.h>

int ap_utils_add_twice(int value) {
    return ap_base_add(value, value, 0);
}

int ap_utils_checksum(int value) {
    return ap_base_multiply(value, 31) + ap_base_add(value, 7, 0);
}
