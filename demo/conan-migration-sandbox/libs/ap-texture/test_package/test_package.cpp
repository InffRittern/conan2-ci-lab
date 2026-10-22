#include <cassert>
#include <cstring>

#include <ap-texture/ap-texture.h>

int main() {
    assert(std::strcmp(ap_texture_format(),
                       "AP_FORMAT_RGBA8_UNORM") == 0);
    assert(ap_texture_supported());
    return 0;
}
