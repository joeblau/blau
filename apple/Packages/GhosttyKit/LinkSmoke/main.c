#include <ghostty.h>

int main(void) {
    // Taking each address forces every advertised embedding entry point to be
    // resolved without initializing Ghostty outside an application runtime.
    __typeof__(&ghostty_config_new) volatile config_symbol = &ghostty_config_new;
    __typeof__(&ghostty_app_new) volatile app_symbol = &ghostty_app_new;
    __typeof__(&ghostty_surface_new) volatile surface_symbol = &ghostty_surface_new;
    return config_symbol == NULL || app_symbol == NULL || surface_symbol == NULL;
}
