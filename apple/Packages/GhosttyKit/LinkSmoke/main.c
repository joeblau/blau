#include <ghostty.h>

int main(void) {
    // Taking the address forces the linker to resolve the embedding entry
    // point without initializing Ghostty outside an application runtime.
    ghostty_config_t (*volatile symbol)(void) = ghostty_config_new;
    return symbol == NULL;
}
