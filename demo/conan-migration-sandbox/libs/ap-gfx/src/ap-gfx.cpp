#include <ap-gfx/ap-gfx.h>

#include <ap-utils/ap-utils.h>
#include <ap-base/ap-base.h>

int ap_gfx_pixels(int width, int height) {
    return ap_utils_add_twice(width * height);
}

int ap_gfx_score(int seed) {
    return ap_utils_checksum(seed) + ap_base_add(seed, 1);
}
