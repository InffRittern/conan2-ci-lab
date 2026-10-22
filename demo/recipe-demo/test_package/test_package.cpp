#include <recipe_demo/recipe_demo.h>

#include <cassert>
#include <iostream>

int main() {
    assert(recipe_demo_greeting() == "recipe-demo");
    std::cout << "recipe-demo: " << recipe_demo_greeting() << '\n';
    return 0;
}
