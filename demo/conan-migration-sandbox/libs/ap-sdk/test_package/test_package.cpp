#include <cassert>
#include <cstring>

#include <ap-sdk/ap-sdk.h>

int main() {
    assert(ap_sdk_render(2, 3) == 13);
    assert(std::strcmp(ap_sdk_name(), "ap-sdk") == 0);
    return 0;
}
