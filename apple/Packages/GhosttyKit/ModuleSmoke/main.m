@import GhosttyKit;

int module_smoke(void) {
    __typeof__(&ghostty_config_new) volatile config_symbol = &ghostty_config_new;
    __typeof__(&ghostty_app_new) volatile app_symbol = &ghostty_app_new;
    __typeof__(&ghostty_surface_new) volatile surface_symbol = &ghostty_surface_new;
    return config_symbol == 0 || app_symbol == 0 || surface_symbol == 0;
}
