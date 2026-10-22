#include <cassert>

#include <ap-utils/ap-utils.h>

int main() {
    assert(ap_utils_add_twice(4) == 8);
    assert(ap_utils_checksum(2) == 71);
    return 0;
}
