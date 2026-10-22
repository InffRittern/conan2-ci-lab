#include <cassert>
#include <cstring>

#include <ap-base/ap-base.h>

int main() {
    assert(ap_base_add(2, 3) == 5);
    assert(ap_base_multiply(4, 5) == 20);
    assert(ap_base_version() != nullptr);
    assert(std::strlen(ap_base_version()) > 0);
    return 0;
}
