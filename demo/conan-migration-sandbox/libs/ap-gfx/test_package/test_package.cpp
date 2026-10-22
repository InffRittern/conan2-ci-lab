#include <cassert>

#include <ap-gfx/ap-gfx.h>

int main() {
    assert(ap_gfx_pixels(2, 3) == 12);
    assert(ap_gfx_score(1) == 41);
    return 0;
}
