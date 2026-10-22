#include <cassert>
#include <cstring>

#include <ap-headers/ap-headers.h>

int main() {
    assert(ap_headers_version() != nullptr);
    assert(std::strlen(ap_headers_version()) > 0);
    assert(ap_headers_major() >= 1);
    return 0;
}
