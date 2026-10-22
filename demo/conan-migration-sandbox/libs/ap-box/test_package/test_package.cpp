#include <cassert>
#include <cstring>

#include <ap-box/ap-box.h>

int main() {
    assert(std::strcmp(ap_box_backend(), "graphics") == 0);
    assert(ap_box_api_major() == 1);
    return 0;
}
