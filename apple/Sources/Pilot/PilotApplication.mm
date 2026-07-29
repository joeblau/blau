#import <AppKit/AppKit.h>

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED
#if !__has_include("include/cef_application_mac.h")
#error "BLAU_CHROMIUM_CEF_ENABLED requires the pinned CEF headers"
#endif
#include "include/cef_application_mac.h"
#import <ChromiumKit/ChromiumKit.h>

@interface PilotApplication : NSApplication <CefAppProtocol> {
    BOOL _handlingSendEvent;
    BOOL _chromiumTerminationPending;
}
- (void)finishChromiumTermination:(id)sender;
@end

@implementation PilotApplication

- (BOOL)isHandlingSendEvent {
    return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent sendingEvent;
    [super sendEvent:event];
}

- (void)terminate:(id)sender {
    ChromiumEngine *engine = ChromiumEngine.shared;
    if (engine.state == ChromiumEngineStateNotStarted ||
        engine.state == ChromiumEngineStateFailed ||
        engine.state == ChromiumEngineStateShutDown) {
        [super terminate:sender];
        return;
    }
    if (_chromiumTerminationPending) {
        return;
    }
    _chromiumTerminationPending = YES;
    __weak PilotApplication *weakSelf = self;
    [engine shutdownWithCompletion:^{
        PilotApplication *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_chromiumTerminationPending = NO;
        [strongSelf finishChromiumTermination:sender];
    }];
}

- (void)finishChromiumTermination:(id)sender {
    [super terminate:sender];
}

@end

#else

@interface PilotApplication : NSApplication
@end

@implementation PilotApplication
@end

#endif
