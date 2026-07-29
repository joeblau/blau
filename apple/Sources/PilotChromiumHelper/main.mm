#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstring>
#include <sysexits.h>

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED
#if !__has_include("include/cef_app.h")
#error "The Chromium build configuration requires the pinned CEF headers. Run apple/bin/update-chromiumkit-artifact.sh first."
#endif
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#endif

static bool HasForbiddenNoSandboxArgument(int argc, char *const argv[]) {
    constexpr const char *argument = "--no-sandbox";
    constexpr size_t argumentLength = 12;

    for (int index = 1; index < argc; ++index) {
        const char *candidate = argv[index];
        if (candidate == nullptr) {
            continue;
        }
        if (std::strncmp(candidate, argument, argumentLength) == 0 &&
            (candidate[argumentLength] == '\0' ||
             candidate[argumentLength] == '=')) {
            return true;
        }
    }
    return false;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (HasForbiddenNoSandboxArgument(argc, argv)) {
            std::fprintf(stderr,
                         "Pilot Chromium helpers refuse --no-sandbox.\n");
            return EX_USAGE;
        }

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED
        CefScopedSandboxContext sandboxContext;
        if (!sandboxContext.Initialize(argc, argv)) {
            std::fprintf(stderr,
                         "Pilot Chromium helper sandbox initialization failed.\n");
            return EX_OSERR;
        }

        CefScopedLibraryLoader libraryLoader;
        if (!libraryLoader.LoadInHelper()) {
            std::fprintf(stderr,
                         "Pilot Chromium helper could not load the pinned CEF framework.\n");
            return EX_UNAVAILABLE;
        }

        CefMainArgs mainArguments(argc, argv);
        return CefExecuteProcess(mainArguments, nullptr, nullptr);
#else
        std::fprintf(
            stderr,
            "The pinned Chromium runtime is not enabled in this build.\n");
        return EX_UNAVAILABLE;
#endif
    }
}
