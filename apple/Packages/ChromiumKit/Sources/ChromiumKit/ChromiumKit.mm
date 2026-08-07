#import <ChromiumKit/ChromiumKit.h>
#import <CoreServices/CoreServices.h>

NSErrorDomain const ChromiumKitErrorDomain = @"app.blau.ChromiumKit";

static NSError *ChromiumKitError(ChromiumKitErrorCode code,
                                 NSString *description,
                                 NSDictionary *extra) {
    NSMutableDictionary *userInfo =
        [@{NSLocalizedDescriptionKey: description} mutableCopy];
    [userInfo addEntriesFromDictionary:extra ?: @{}];
    return [NSError errorWithDomain:ChromiumKitErrorDomain
                               code:code
                           userInfo:userInfo];
}

#if !defined(BLAU_CHROMIUM_CEF_ENABLED) || !BLAU_CHROMIUM_CEF_ENABLED
static NSError *ChromiumKitUnavailableError(void) {
    return ChromiumKitError(
        ChromiumKitErrorRuntimeUnavailable,
        @"The Chromium runtime is not installed.",
        @{NSLocalizedRecoverySuggestionErrorKey:
              @"Install the pinned CEF artifact and build Pilot with its "
               "Chromium configuration."});
}
#endif

BOOL ChromiumKitApplyDownloadQuarantine(NSURL *fileURL, NSError **error) {
    if (!fileURL.isFileURL) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorDownloadQuarantineFailed,
                @"Download quarantine requires a local file URL.",
                nil);
        }
        return NO;
    }

    NSNumber *isRegularFile = nil;
    NSError *resourceError = nil;
    if (![fileURL getResourceValue:&isRegularFile
                            forKey:NSURLIsRegularFileKey
                             error:&resourceError] ||
        !isRegularFile.boolValue) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorDownloadQuarantineFailed,
                @"Download quarantine requires an existing regular file.",
                resourceError ? @{NSUnderlyingErrorKey: resourceError} : nil);
        }
        return NO;
    }

    NSString *bundleIdentifier =
        NSBundle.mainBundle.bundleIdentifier ?: @"app.blau.pilot";
    NSDictionary *properties = @{
        (__bridge NSString *)kLSQuarantineTypeKey:
            (__bridge NSString *)kLSQuarantineTypeWebDownload,
        (__bridge NSString *)kLSQuarantineAgentBundleIdentifierKey:
            bundleIdentifier,
        (__bridge NSString *)kLSQuarantineAgentNameKey:
            NSProcessInfo.processInfo.processName,
        (__bridge NSString *)kLSQuarantineTimeStampKey: NSDate.date,
    };
    if ([fileURL setResourceValue:properties
                           forKey:NSURLQuarantinePropertiesKey
                            error:&resourceError]) {
        return YES;
    }
    if (error) {
        *error = ChromiumKitError(
            ChromiumKitErrorDownloadQuarantineFailed,
            @"Pilot could not quarantine the downloaded file.",
            resourceError ? @{NSUnderlyingErrorKey: resourceError} : nil);
    }
    return NO;
}

@interface ChromiumEngine ()
@property (nonatomic, readwrite) ChromiumEngineState state;
@property (nonatomic) NSMutableArray *shutdownCompletions;
- (void)chromiumDidFinishShutdown;
@end

@interface ChromiumBrowserHostView ()
@property (nonatomic, readwrite) ChromiumBrowserLifecycleState lifecycleState;
@property (nonatomic, readwrite, nullable) NSURL *URL;
@property (nonatomic, readwrite, nullable) NSString *title;
@property (nonatomic, readwrite, getter=isLoading) BOOL loading;
@property (nonatomic, readwrite) double estimatedProgress;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@property (nonatomic, readwrite) double zoomLevel;
@property (nonatomic) NSUInteger chromiumToken;
@property (nonatomic, nullable) NSURL *pendingURL;
@property (nonatomic) BOOL closeDelivered;
- (void)cefDidCreate;
- (void)cefDidChangeURL:(NSURL *)URL;
- (void)cefDidChangeTitle:(nullable NSString *)title;
- (void)cefDidChangeLoading:(BOOL)loading
                  canGoBack:(BOOL)canGoBack
               canGoForward:(BOOL)canGoForward;
- (void)cefDidChangeProgress:(double)progress;
- (void)cefDidFail:(NSError *)error;
- (void)cefRendererTerminated:(ChromiumRendererTerminationStatus)status;
- (void)cefDidUpdateFindMatchCount:(NSInteger)matchCount
                activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                       finalUpdate:(BOOL)finalUpdate;
- (void)cefDidUpdateDownloadWithIdentifier:(NSUInteger)identifier
                                       URL:(NSURL *)URL
                         suggestedFilename:(NSString *)suggestedFilename
                             receivedBytes:(int64_t)receivedBytes
                                totalBytes:(int64_t)totalBytes
                           percentComplete:(NSInteger)percentComplete
                                     state:(ChromiumDownloadState)state;
- (void)cefDidRejectAuthenticationForURL:(nullable NSURL *)URL;
- (void)cefDidRejectCertificateError:(NSInteger)errorCode
                              forURL:(nullable NSURL *)URL;
- (void)cefDidRejectClientCertificateForHost:(NSString *)host
                                        port:(NSInteger)port;
- (void)cefWillClose;
- (void)cefDidClose;
@end

@interface ChromiumContextMenuRequest ()
@property (nonatomic, readwrite) NSPoint location;
@property (nonatomic, readwrite, nullable) NSURL *linkURL;
@property (nonatomic, readwrite, nullable) NSURL *sourceURL;
@property (nonatomic, readwrite) NSString *selectedText;
@property (nonatomic, readwrite, getter=isEditable) BOOL editable;
- (instancetype)initWithLocation:(NSPoint)location
                         linkURL:(nullable NSURL *)linkURL
                       sourceURL:(nullable NSURL *)sourceURL
                    selectedText:(NSString *)selectedText
                        editable:(BOOL)editable;
@end

@implementation ChromiumContextMenuRequest

- (instancetype)initWithLocation:(NSPoint)location
                         linkURL:(NSURL *)linkURL
                       sourceURL:(NSURL *)sourceURL
                    selectedText:(NSString *)selectedText
                        editable:(BOOL)editable {
    self = [super init];
    if (self) {
        _location = location;
        _linkURL = linkURL;
        _sourceURL = sourceURL;
        _selectedText = [selectedText copy];
        _editable = editable;
    }
    return self;
}

@end

@interface ChromiumPermissionRequest ()
@property (nonatomic, readwrite) NSURL *origin;
@property (nonatomic, readwrite) ChromiumPermissionKind kinds;
@property (nonatomic, readwrite) NSUInteger rawPermissionMask;
@property (nonatomic, copy, nullable)
    void (^decisionHandler)(BOOL allowed);
@property (nonatomic) BOOL resolved;
- (instancetype)initWithOrigin:(NSURL *)origin
                         kinds:(ChromiumPermissionKind)kinds
               rawPermissionMask:(NSUInteger)rawPermissionMask
               decisionHandler:(void (^)(BOOL allowed))decisionHandler;
@end

@implementation ChromiumPermissionRequest

- (instancetype)initWithOrigin:(NSURL *)origin
                         kinds:(ChromiumPermissionKind)kinds
             rawPermissionMask:(NSUInteger)rawPermissionMask
               decisionHandler:(void (^)(BOOL allowed))decisionHandler {
    self = [super init];
    if (self) {
        _origin = origin;
        _kinds = kinds;
        _rawPermissionMask = rawPermissionMask;
        _decisionHandler = [decisionHandler copy];
    }
    return self;
}

- (void)allow {
    [self resolve:YES];
}

- (void)deny {
    [self resolve:NO];
}

- (void)resolve:(BOOL)allowed {
    NSCAssert(NSThread.isMainThread, @"Permission decisions require main");
    if (self.resolved) {
        return;
    }
    self.resolved = YES;
    void (^handler)(BOOL) = self.decisionHandler;
    self.decisionHandler = nil;
    if (handler) {
        handler(allowed);
    }
}

@end

#if defined(BLAU_CHROMIUM_CEF_ENABLED) && BLAU_CHROMIUM_CEF_ENABLED


#if !__has_include("include/cef_app.h")
#error "BLAU_CHROMIUM_CEF_ENABLED requires the pinned CEF headers"
#endif

#import <crt_externs.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <limits>
#include <memory>
#include <unordered_map>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

namespace {
/// Comma-separated unpacked extension directories supplied by Pilot before the
/// engine starts. Read once by OnBeforeCommandLineProcessing on the main thread
/// during CefInitialize, so no synchronization is required beyond the documented
/// "set before start" contract.
std::string g_extension_load_paths;
std::string ExtensionLoadPaths() { return g_extension_load_paths; }
}  // namespace

namespace {

class BrowserClient;
class EngineCore;
static EngineCore *g_engine = nullptr;

static NSString *NSStringFromCef(const CefString& value) {
    const std::string utf8 = value.ToString();
    NSString *result =
        [[NSString alloc] initWithBytes:utf8.data()
                                  length:utf8.size()
                                encoding:NSUTF8StringEncoding];
    return result ?: @"";
}

static NSURL *NSURLFromCef(const CefString& value) {
    NSString *string = NSStringFromCef(value);
    return string.length ? [NSURL URLWithString:string] : nil;
}

static ChromiumPermissionKind PermissionKindsFromPrompt(
    uint32_t requested_permissions) {
    ChromiumPermissionKind kinds = 0;
    uint32_t known_permissions = 0;
#define MAP_PERMISSION(cef_kind, chromium_kind) \
    if (requested_permissions & cef_kind) {     \
        kinds |= chromium_kind;                 \
        known_permissions |= cef_kind;          \
    }
    MAP_PERMISSION(CEF_PERMISSION_TYPE_CAMERA_STREAM,
                   ChromiumPermissionKindVideoCapture)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_CLIPBOARD,
                   ChromiumPermissionKindClipboard)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_GEOLOCATION,
                   ChromiumPermissionKindGeolocation)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_MIC_STREAM,
                   ChromiumPermissionKindAudioCapture)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_MIDI_SYSEX,
                   ChromiumPermissionKindMIDISystemExclusive)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_NOTIFICATIONS,
                   ChromiumPermissionKindNotifications)
    MAP_PERMISSION(CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS,
                   ChromiumPermissionKindFileSystemAccess)
#undef MAP_PERMISSION
    if ((requested_permissions & ~known_permissions) != 0 || kinds == 0) {
        kinds |= ChromiumPermissionKindOther;
    }
    return kinds;
}

class ExternalMessagePump final {
 public:
    static ExternalMessagePump& Shared() {
        static ExternalMessagePump *pump = new ExternalMessagePump;
        return *pump;
    }

    void Start() {
        watchdog_work_count_.store(0);
        accepting_.store(true);
        sequence_.fetch_add(1);
        Schedule(0);
    }

    void Stop() {
        accepting_.store(false);
        sequence_.fetch_add(1);
    }

    void Schedule(int64_t delay_ms) {
        if (!accepting_.load()) {
            return;
        }
        const uint64_t token = sequence_.fetch_add(1) + 1;
        Dispatch(token, delay_ms, 0);
    }

    uint64_t WatchdogWorkCount() const {
        return watchdog_work_count_.load();
    }

 private:
    static constexpr int64_t kInitialWatchdogDelayMs = 50;
    static constexpr int64_t kMaximumWatchdogDelayMs = 100;

    void Dispatch(uint64_t token,
                  int64_t delay_ms,
                  int64_t watchdog_delay_ms) {
        dispatch_block_t work = ^{
            ExternalMessagePump::Shared().Run(token, watchdog_delay_ms);
        };
        if (delay_ms <= 0) {
            dispatch_async(dispatch_get_main_queue(), work);
        } else {
            // A newer schedule request invalidates this token. Honor CEF's
            // requested delay exactly instead of installing an idle polling
            // cadence; OnScheduleMessagePumpWork will request the next turn.
            constexpr int64_t maximum_delay_ms =
                std::numeric_limits<int64_t>::max() / NSEC_PER_MSEC;
            const int64_t bounded =
                std::min(delay_ms, maximum_delay_ms);
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, bounded * NSEC_PER_MSEC),
                dispatch_get_main_queue(), work);
        }
    }

    void Run(uint64_t token, int64_t watchdog_delay_ms) {
        if (!accepting_.load() || token != sequence_.load()) {
            return;
        }
        NSCAssert(NSThread.isMainThread, @"CEF pump must run on main");
        if (watchdog_delay_ms > 0) {
            watchdog_work_count_.fetch_add(1);
        }
        CefDoMessageLoopWork();

        // CEF's macOS native-host path does not always request a subsequent
        // turn after CefDoMessageLoopWork. Reserve a low-frequency watchdog
        // only when no callback replaced this token while CEF was running.
        // Any later callback invalidates the watchdog before it can execute.
        uint64_t expected = token;
        const uint64_t watchdog_token = token + 1;
        if (!accepting_.load()
            || !sequence_.compare_exchange_strong(
                expected, watchdog_token
            )) {
            return;
        }
        const int64_t next_delay = watchdog_delay_ms > 0
            ? std::min(
                watchdog_delay_ms * 2,
                kMaximumWatchdogDelayMs
            )
            : kInitialWatchdogDelayMs;
        Dispatch(watchdog_token, next_delay, next_delay);
    }

    std::atomic<bool> accepting_{false};
    std::atomic<uint64_t> sequence_{0};
    std::atomic<uint64_t> watchdog_work_count_{0};
};

class ChromiumApp final : public CefApp,
                          public CefBrowserProcessHandler {
 public:
    explicit ChromiumApp(EngineCore *engine) : engine_(engine) {}

    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        if (process_type.empty()) {
            // Chrome runtime otherwise owns the login prompt and bypasses
            // CefRequestHandler::GetAuthCredentials. Route challenges through
            // our fail-closed handler without accepting external switches.
            command_line->AppendSwitch("disable-chrome-login-prompt");
            // Side-load unpacked wallet extensions through Chrome's own
            // mechanism: CEF 150 exposes no programmatic extension API (see
            // chromiumembedded/cef#3450), so the switch is the only route.
            // App-appended switches are still honored with
            // command_line_args_disabled, which only blocks external/OS-
            // provided arguments.
            //
            // The directories come from Pilot, which discovers them at runtime.
            // They must never be hardcoded: Chrome derives an unpacked
            // extension's ID from its absolute path, so a baked-in path both
            // breaks on every other machine and silently invalidates the IDs
            // used to address the extension's UI.
            const std::string extension_paths = ExtensionLoadPaths();
            if (!extension_paths.empty()) {
                command_line->AppendSwitchWithValue("load-extension",
                                                    extension_paths);
            }
        }
    }

    void OnContextInitialized() override;

    bool OnAlreadyRunningAppRelaunch(
        CefRefPtr<CefCommandLine> command_line,
        const CefString& current_directory) override {
        CEF_REQUIRE_UI_THREAD();
        [NSApp activateIgnoringOtherApps:YES];
        return true;
    }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        ExternalMessagePump::Shared().Schedule(delay_ms);
    }

 private:
    EngineCore *engine_;
    IMPLEMENT_REFCOUNTING(ChromiumApp);
};

class BrowserClient final : public CefClient,
                            public CefContextMenuHandler,
                            public CefDialogHandler,
                            public CefDisplayHandler,
                            public CefDownloadHandler,
                            public CefFindHandler,
                            public CefLifeSpanHandler,
                            public CefLoadHandler,
                            public CefPermissionHandler,
                            public CefRequestHandler,
                            public CefResourceRequestHandler {
 public:
    BrowserClient(EngineCore *engine,
                  uint64_t token,
                  ChromiumBrowserHostView *host)
        : engine_(engine), token_(token), host_(host) {}

    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
        return this;
    }
    CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
        return this;
    }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        CefRefPtr<CefRequest> request,
        bool is_navigation,
        bool is_download,
        const CefString& request_initiator,
        bool& disable_default_handling) override {
        disable_default_handling = false;
        return this;
    }

    void Create();
    void Close(bool force);
    void DetachHost();
    void Load(NSURL *URL);
    void Back();
    void Forward();
    void Reload();
    void Stop();
    void Focus();
    void SetZoom(double level);
    void OpenDevTools();
    void CloseDevTools();
    void Find(NSString *text, bool forward, bool match_case, bool find_next);
    void StopFinding(bool clear_selection);
    void PrintPage();
    void SavePage();
    bool ExecuteJavaScript(NSString *script, NSURL *source_url, NSInteger line);
    bool SendMouseClick(NSPoint point);
    void Layout();

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request,
                        bool user_gesture,
                        bool is_redirect) override;
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popup_features,
                       CefWindowInfo& window_info,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override;
    void OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefRequest> request,
                             bool& allow_os_execution) override;
    bool OnRequestMediaAccessPermission(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefMediaAccessCallback> callback) override;
    bool OnShowPermissionPrompt(
        CefRefPtr<CefBrowser> browser,
        uint64_t prompt_id,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefPermissionPromptCallback> callback) override;
    bool CanDownload(CefRefPtr<CefBrowser> browser,
                     const CefString& url,
                     const CefString& request_method) override;
    bool OnBeforeDownload(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefDownloadItem> download_item,
        const CefString& suggested_name,
        CefRefPtr<CefBeforeDownloadCallback> callback) override;
    void OnDownloadUpdated(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefDownloadItem> download_item,
        CefRefPtr<CefDownloadItemCallback> callback) override;
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override;
    bool OnFileDialog(
        CefRefPtr<CefBrowser> browser,
        FileDialogMode mode,
        const CefString& title,
        const CefString& default_file_path,
        const std::vector<CefString>& accept_filters,
        const std::vector<CefString>& accept_extensions,
        const std::vector<CefString>& accept_descriptions,
        CefRefPtr<CefFileDialogCallback> callback) override;
    void OnFindResult(CefRefPtr<CefBrowser> browser,
                      int identifier,
                      int count,
                      const CefRect& selection_rect,
                      int active_match_ordinal,
                      bool final_update) override;
    bool GetAuthCredentials(CefRefPtr<CefBrowser> browser,
                            const CefString& origin_url,
                            bool is_proxy,
                            const CefString& host,
                            int port,
                            const CefString& realm,
                            const CefString& scheme,
                            CefRefPtr<CefAuthCallback> callback) override;
    bool OnCertificateError(CefRefPtr<CefBrowser> browser,
                            cef_errorcode_t cert_error,
                            const CefString& request_url,
                            CefRefPtr<CefSSLInfo> ssl_info,
                            CefRefPtr<CefCallback> callback) override;
    bool OnSelectClientCertificate(
        CefRefPtr<CefBrowser> browser,
        bool is_proxy,
        const CefString& host,
        int port,
        const X509CertificateList& certificates,
        CefRefPtr<CefSelectClientCertificateCallback> callback) override;
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
    bool DoClose(CefRefPtr<CefBrowser> browser) override;
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override;
    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override;
    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                 double progress) override;
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool is_loading,
                              bool can_go_back,
                              bool can_go_forward) override;
    void OnLoadError(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     ErrorCode error_code,
                     const CefString& error_text,
                     const CefString& failed_url) override;
    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                   TerminationStatus status,
                                   int error_code,
                                   const CefString& error_string) override;

 private:
    bool IsCurrent(CefRefPtr<CefBrowser> browser) const {
        return browser_ && browser_->IsSame(browser);
    }
    void FinishWithoutBrowser(NSError *error);

    EngineCore *engine_;
    const uint64_t token_;
    __weak ChromiumBrowserHostView *host_;
    CefRefPtr<CefBrowser> browser_;
    bool create_requested_ = false;
    bool closing_ = false;
    bool closed_ = false;
    IMPLEMENT_REFCOUNTING(BrowserClient);
};

class EngineCore final {
 public:
    explicit EngineCore(ChromiumEngine *owner) : owner_(owner) {}

    bool Start(NSURL *profile, NSError **error) {
        NSCAssert(NSThread.isMainThread, @"CEF must initialize on main");
        loader_ = std::make_unique<CefScopedLibraryLoader>();
        if (!loader_->LoadInMain()) {
            if (error) {
                *error = ChromiumKitError(
                    ChromiumKitErrorLibraryLoadFailed,
                    @"The Chromium Embedded Framework could not be loaded.",
                    nil);
            }
            loader_.reset();
            return false;
        }

        CefSettings settings;
        settings.no_sandbox = false;
        settings.multi_threaded_message_loop = false;
        settings.external_message_pump = true;
        settings.windowless_rendering_enabled = false;
        settings.command_line_args_disabled = true;
        // SPIKE(rabby-extension): CEF 150 removed CefSettings::chrome_runtime
        // (Chrome runtime is now the only runtime) and the old
        // CefRequestContext::LoadExtension API; programmatic extension
        // management is still open upstream (chromiumembedded/cef#3450), so
        // extensions load via the load-extension switch below.
        const char *path = profile.path.fileSystemRepresentation;
        CefString(&settings.root_cache_path) = path;
        CefString(&settings.cache_path) = path;

        app_ = new ChromiumApp(this);
        ExternalMessagePump::Shared().Start();
        CefMainArgs main_args(*_NSGetArgc(), *_NSGetArgv());
        if (!CefInitialize(main_args, settings, app_, nullptr)) {
            const int exit_code = CefGetExitCode();
            ExternalMessagePump::Shared().Stop();
            app_ = nullptr;
            loader_.reset();
            if (error) {
                *error = ChromiumKitError(
                    ChromiumKitErrorInitializationFailed,
                    @"CEF initialization failed.",
                    @{@"CEFExitCode": @(exit_code)});
            }
            return false;
        }
        initialized_ = true;
        return true;
    }

    uint64_t AddHost(ChromiumBrowserHostView *host) {
        if (shutting_down_ || !initialized_) {
            return 0;
        }
        const uint64_t token = next_token_++;
        CefRefPtr<BrowserClient> client =
            new BrowserClient(this, token, host);
        clients_.emplace(token, client);
        if (context_ready_) {
            client->Create();
        }
        return token;
    }

    CefRefPtr<BrowserClient> Client(uint64_t token) {
        auto found = clients_.find(token);
        return found == clients_.end() ? nullptr : found->second;
    }

    size_t ClientCount() const {
        return clients_.size();
    }

    void ContextReady() {
        CEF_REQUIRE_UI_THREAD();
        context_ready_ = true;
        if (shutting_down_) {
            return;
        }
        owner_.state = ChromiumEngineStateRunning;
        std::vector<CefRefPtr<BrowserClient>> pending;
        for (const auto& entry : clients_) {
            pending.push_back(entry.second);
        }
        for (const auto& client : pending) {
            client->Create();
        }
    }

    void ClientClosed(uint64_t token) {
        clients_.erase(token);
        FinishShutdownIfReady();
    }

    void Shutdown() {
        NSCAssert(NSThread.isMainThread, @"CEF must shut down on main");
        if (!initialized_ || shutting_down_) {
            return;
        }
        shutting_down_ = true;
        owner_.state = ChromiumEngineStateShuttingDown;
        std::vector<CefRefPtr<BrowserClient>> active;
        for (const auto& entry : clients_) {
            active.push_back(entry.second);
        }
        for (const auto& client : active) {
            client->Close(true);
        }
        FinishShutdownIfReady();
    }

 private:
    void FinishShutdownIfReady() {
        if (!shutting_down_ || !clients_.empty() || finish_scheduled_) {
            return;
        }
        finish_scheduled_ = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_engine != nullptr) {
                g_engine->FinishShutdown();
            }
        });
    }

    void FinishShutdown() {
        if (!initialized_ || !clients_.empty()) {
            finish_scheduled_ = false;
            return;
        }
        ExternalMessagePump::Shared().Stop();
        CefShutdown();
        initialized_ = false;
        context_ready_ = false;
        app_ = nullptr;
        loader_.reset();
        ChromiumEngine *owner = owner_;
        g_engine = nullptr;
        delete this;
        [owner chromiumDidFinishShutdown];
    }

    friend class BrowserClient;
    __weak ChromiumEngine *owner_;
    std::unique_ptr<CefScopedLibraryLoader> loader_;
    CefRefPtr<ChromiumApp> app_;
    std::unordered_map<uint64_t, CefRefPtr<BrowserClient>> clients_;
    uint64_t next_token_ = 1;
    bool initialized_ = false;
    bool context_ready_ = false;
    bool shutting_down_ = false;
    bool finish_scheduled_ = false;
};

void ChromiumApp::OnContextInitialized() {
    CEF_REQUIRE_UI_THREAD();
    engine_->ContextReady();
}

void BrowserClient::Create() {
    CEF_REQUIRE_UI_THREAD();
    if (create_requested_ || closed_) {
        return;
    }
    if (closing_ || host_ == nil) {
        FinishWithoutBrowser(nil);
        return;
    }

    ChromiumBrowserHostView *host = host_;
    CefWindowInfo window_info;
    const int width = std::max(1, static_cast<int>(NSWidth(host.bounds)));
    const int height = std::max(1, static_cast<int>(NSHeight(host.bounds)));
    window_info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(host),
                           CefRect(0, 0, width, height));
    // SPIKE(rabby-extension): Chrome-style windows so extension UI (action
    // popups, tabs APIs) behaves; was CEF_RUNTIME_STYLE_ALLOY.
    window_info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    CefBrowserSettings settings;
    create_requested_ = true;
    if (!CefBrowserHost::CreateBrowser(window_info, this, "about:blank",
                                       settings, nullptr, nullptr)) {
        FinishWithoutBrowser(ChromiumKitError(
            ChromiumKitErrorBrowserCreationFailed,
            @"CEF rejected the browser creation request.", nil));
    }
}

void BrowserClient::Close(bool force) {
    CEF_REQUIRE_UI_THREAD();
    if (closed_) {
        return;
    }
    if (closing_) {
        if (force && browser_) {
            browser_->GetHost()->CloseBrowser(true);
        }
        return;
    }
    closing_ = true;
    [host_ cefWillClose];
    if (browser_) {
        browser_->GetHost()->CloseBrowser(force);
    } else if (!create_requested_) {
        FinishWithoutBrowser(nil);
    }
}

void BrowserClient::DetachHost() {
    CEF_REQUIRE_UI_THREAD();
    host_ = nil;
    Close(true);
}

void BrowserClient::FinishWithoutBrowser(NSError *error) {
    CefRefPtr<BrowserClient> keep_alive(this);
    if (closed_) {
        return;
    }
    closed_ = true;
    if (error) {
        [host_ cefDidFail:error];
    }
    [host_ cefDidClose];
    host_ = nil;
    engine_->ClientClosed(token_);
}

void BrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (browser_) {
        return;
    }
    browser_ = browser;
    Layout();
    if (closing_ || host_ == nil) {
        browser_->GetHost()->CloseBrowser(true);
        return;
    }
    [host_ cefDidCreate];
}

bool BrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (!IsCurrent(browser)) {
        return false;
    }
    closing_ = true;
    [host_ cefWillClose];
    NSView *browser_view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [browser_view removeFromSuperview];
    return false;
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
    CEF_REQUIRE_UI_THREAD();
    if (!IsCurrent(browser)) {
        return;
    }
    CefRefPtr<BrowserClient> keep_alive(this);
    browser_ = nullptr;
    closed_ = true;
    [host_ cefDidClose];
    host_ = nil;
    engine_->ClientClosed(token_);
}

void BrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    const CefString& url) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser) && frame->IsMain()) {
        NSURL *URL = [NSURL URLWithString:NSStringFromCef(url)];
        if (URL) {
            [host_ cefDidChangeURL:URL];
        }
    }
}

bool BrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   bool user_gesture,
                                   bool is_redirect) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !IsCurrent(browser) || !frame->IsMain()) {
        return false;
    }
    NSURL *URL = [NSURL URLWithString:NSStringFromCef(request->GetURL())];
    if (!URL) {
        return true;
    }

    ChromiumNavigationDecision decision = ChromiumNavigationDecisionAllow;
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:decideNavigationToURL:
                                                userGesture:isRedirect:);
    if ([delegate respondsToSelector:selector]) {
        decision = [delegate chromiumBrowserHostView:host
                              decideNavigationToURL:URL
                                        userGesture:user_gesture
                                         isRedirect:is_redirect];
    }
    if (decision == ChromiumNavigationDecisionOpenExternally) {
        SEL externalSelector =
            @selector(chromiumBrowserHostView:shouldOpenExternalURL:);
        if ([delegate respondsToSelector:externalSelector] &&
            [delegate chromiumBrowserHostView:host
                        shouldOpenExternalURL:URL]) {
            [NSWorkspace.sharedWorkspace openURL:URL];
        }
        return true;
    }
    return decision == ChromiumNavigationDecisionCancel;
}

bool BrowserClient::OnBeforePopup(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    int popup_id,
    const CefString& target_url,
    const CefString& target_frame_name,
    WindowOpenDisposition target_disposition,
    bool user_gesture,
    const CefPopupFeatures& popup_features,
    CefWindowInfo& window_info,
    CefRefPtr<CefClient>& client,
    CefBrowserSettings& settings,
    CefRefPtr<CefDictionaryValue>& extra_info,
    bool* no_javascript_access) {
    CEF_REQUIRE_UI_THREAD();
    if (!IsCurrent(browser)) {
        return true;
    }

    ChromiumPopupDisposition disposition = ChromiumPopupDispositionUnknown;
    switch (target_disposition) {
        case CEF_WOD_NEW_FOREGROUND_TAB:
            disposition = ChromiumPopupDispositionForegroundTab;
            break;
        case CEF_WOD_NEW_BACKGROUND_TAB:
            disposition = ChromiumPopupDispositionBackgroundTab;
            break;
        case CEF_WOD_NEW_POPUP:
            disposition = ChromiumPopupDispositionPopup;
            break;
        case CEF_WOD_NEW_WINDOW:
            disposition = ChromiumPopupDispositionWindow;
            break;
        default:
            break;
    }
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRequestPopup:disposition:
                                                      userGesture:);
    if ([delegate respondsToSelector:selector]) {
        NSString *target = NSStringFromCef(target_url);
        NSURL *URL = target.length ? [NSURL URLWithString:target] : nil;
        if (!URL) {
            return true;
        }
        [delegate chromiumBrowserHostView:host
                         didRequestPopup:URL
                             disposition:disposition
                             userGesture:user_gesture];
    }
    // Popups are always canceled here. Pilot may create a managed pane from
    // the typed delegate callback, but CEF never creates an unmanaged window.
    return true;
}

void BrowserClient::OnProtocolExecution(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        CefRefPtr<CefRequest> request,
                                        bool& allow_os_execution) {
    // This CefResourceRequestHandler callback runs on the IO thread. Unknown
    // protocols are always denied here; user-confirmed external opens are
    // performed explicitly from OnBeforeBrowse on the UI thread.
    allow_os_execution = false;
}

bool BrowserClient::OnRequestMediaAccessPermission(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefMediaAccessCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumPermissionKind kinds = 0;
    uint32_t known_permissions = 0;
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
        kinds |= ChromiumPermissionKindAudioCapture;
        known_permissions |= CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
    }
    if (requested_permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
        kinds |= ChromiumPermissionKindVideoCapture;
        known_permissions |= CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    }
    if ((requested_permissions & ~known_permissions) != 0 || kinds == 0) {
        kinds |= ChromiumPermissionKindOther;
    }
    NSURL *origin =
        [NSURL URLWithString:NSStringFromCef(requesting_origin)] ?:
        [NSURL URLWithString:@"about:blank"];
    CefRefPtr<CefMediaAccessCallback> retained = callback;
    ChromiumPermissionRequest *permission =
        [[ChromiumPermissionRequest alloc]
            initWithOrigin:origin
                     kinds:kinds
         rawPermissionMask:requested_permissions
           decisionHandler:^(BOOL allowed) {
               retained->Continue(allowed ? requested_permissions : 0);
           }];
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRequestPermission:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:host
                     didRequestPermission:permission];
    } else {
        [permission deny];
    }
    return true;
}

bool BrowserClient::OnShowPermissionPrompt(
    CefRefPtr<CefBrowser> browser,
    uint64_t prompt_id,
    const CefString& requesting_origin,
    uint32_t requested_permissions,
    CefRefPtr<CefPermissionPromptCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    NSURL *origin =
        [NSURL URLWithString:NSStringFromCef(requesting_origin)] ?:
        [NSURL URLWithString:@"about:blank"];
    CefRefPtr<CefPermissionPromptCallback> retained = callback;
    ChromiumPermissionRequest *permission =
        [[ChromiumPermissionRequest alloc]
            initWithOrigin:origin
                     kinds:PermissionKindsFromPrompt(requested_permissions)
         rawPermissionMask:requested_permissions
           decisionHandler:^(BOOL allowed) {
               retained->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT
                                          : CEF_PERMISSION_RESULT_DENY);
           }];
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRequestPermission:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:host
                     didRequestPermission:permission];
    } else {
        [permission deny];
    }
    return true;
}

bool BrowserClient::CanDownload(CefRefPtr<CefBrowser> browser,
                                const CefString& url,
                                const CefString& request_method) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    return !closing_ && IsCurrent(browser) &&
           [delegate respondsToSelector:
               @selector(chromiumBrowserHostView:shouldDownloadURL:
                                                   suggestedFilename:)];
}

bool BrowserClient::OnBeforeDownload(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    const CefString& suggested_name,
    CefRefPtr<CefBeforeDownloadCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:shouldDownloadURL:
                                            suggestedFilename:);
    NSURL *URL = [NSURL URLWithString:NSStringFromCef(download_item->GetURL())];
    NSString *name = NSStringFromCef(suggested_name);
    if (!URL || ![delegate respondsToSelector:selector] ||
        ![delegate chromiumBrowserHostView:host
                        shouldDownloadURL:URL
                        suggestedFilename:name]) {
        return false;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = name.lastPathComponent;
    CefRefPtr<CefBeforeDownloadCallback> retained = callback;
    void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) {
            retained->Continue(panel.URL.path.UTF8String, false);
        }
    };
    if (host.window) {
        [panel beginSheetModalForWindow:host.window
                     completionHandler:completion];
    } else {
        [panel beginWithCompletionHandler:completion];
    }
    return true;
}

void BrowserClient::OnDownloadUpdated(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefDownloadItem> download_item,
    CefRefPtr<CefDownloadItemCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    if (closing_ || !host || !IsCurrent(browser)) {
        if (download_item->IsValid() && download_item->IsInProgress()) {
            callback->Cancel();
        }
        return;
    }
    if (!download_item->IsValid()) {
        return;
    }
    NSURL *URL = NSURLFromCef(download_item->GetURL());
    if (!URL) {
        if (download_item->IsInProgress()) {
            callback->Cancel();
        }
        return;
    }
    ChromiumDownloadState state = ChromiumDownloadStateInProgress;
    if (download_item->IsCanceled()) {
        state = ChromiumDownloadStateCanceled;
    } else if (download_item->IsInterrupted()) {
        state = ChromiumDownloadStateInterrupted;
    } else if (download_item->IsComplete()) {
        NSString *fullPath = NSStringFromCef(download_item->GetFullPath());
        NSURL *fileURL = fullPath.length
            ? [NSURL fileURLWithPath:fullPath]
            : nil;
        NSError *quarantineError = nil;
        if (fileURL &&
            ChromiumKitApplyDownloadQuarantine(fileURL, &quarantineError)) {
            state = ChromiumDownloadStateComplete;
        } else {
            if (fileURL) {
                [NSFileManager.defaultManager removeItemAtURL:fileURL
                                                        error:nil];
            }
            state = ChromiumDownloadStateInterrupted;
        }
    }
    [host cefDidUpdateDownloadWithIdentifier:download_item->GetId()
                                         URL:URL
                           suggestedFilename:
                               NSStringFromCef(
                                   download_item->GetSuggestedFileName())
                               receivedBytes:download_item->GetReceivedBytes()
                                  totalBytes:download_item->GetTotalBytes()
                             percentComplete:
                                 download_item->GetPercentComplete()
                                       state:state];
}

void BrowserClient::OnBeforeContextMenu(
    CefRefPtr<CefBrowser> browser,
    CefRefPtr<CefFrame> frame,
    CefRefPtr<CefContextMenuParams> params,
    CefRefPtr<CefMenuModel> model) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:shouldPresentContextMenu:);
    if (closing_ || !host || !IsCurrent(browser) ||
        ![delegate respondsToSelector:selector]) {
        model->Clear();
        return;
    }
    ChromiumContextMenuRequest *request =
        [[ChromiumContextMenuRequest alloc]
            initWithLocation:NSMakePoint(params->GetXCoord(),
                                         params->GetYCoord())
                     linkURL:NSURLFromCef(params->GetLinkUrl())
                   sourceURL:NSURLFromCef(params->GetSourceUrl())
                selectedText:NSStringFromCef(params->GetSelectionText())
                    editable:params->IsEditable()];
    if (![delegate chromiumBrowserHostView:host
                  shouldPresentContextMenu:request]) {
        model->Clear();
        return;
    }
    model->Remove(MENU_ID_FIND);
    model->Remove(MENU_ID_PRINT);
    model->Remove(MENU_ID_VIEW_SOURCE);
    for (int command = MENU_ID_CUSTOM_FIRST;
         command <= MENU_ID_CUSTOM_LAST; ++command) {
        model->Remove(command);
    }
}

bool BrowserClient::OnFileDialog(
    CefRefPtr<CefBrowser> browser,
    FileDialogMode mode,
    const CefString& title,
    const CefString& default_file_path,
    const std::vector<CefString>& accept_filters,
    const std::vector<CefString>& accept_extensions,
    const std::vector<CefString>& accept_descriptions,
    CefRefPtr<CefFileDialogCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostViewShouldPresentFileChooser:);
    if (![delegate respondsToSelector:selector] ||
        ![delegate chromiumBrowserHostViewShouldPresentFileChooser:host]) {
        callback->Cancel();
        return true;
    }

    const cef_file_dialog_mode_t dialog_type = mode;
    CefRefPtr<CefFileDialogCallback> retained = callback;
    NSString *panelTitle = NSStringFromCef(title);
    NSString *defaultPath = NSStringFromCef(default_file_path);
    if (dialog_type == FILE_DIALOG_SAVE) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        panel.title = panelTitle;
        panel.nameFieldStringValue = defaultPath.lastPathComponent;
        void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
            if (response == NSModalResponseOK && panel.URL) {
                std::vector<CefString> paths{
                    CefString(panel.URL.path.UTF8String)};
                retained->Continue(paths);
            } else {
                retained->Cancel();
            }
        };
        if (host.window) {
            [panel beginSheetModalForWindow:host.window
                         completionHandler:completion];
        } else {
            [panel beginWithCompletionHandler:completion];
        }
        return true;
    }

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = panelTitle;
    panel.allowsMultipleSelection =
        dialog_type == FILE_DIALOG_OPEN_MULTIPLE;
    panel.canChooseDirectories = dialog_type == FILE_DIALOG_OPEN_FOLDER;
    panel.canChooseFiles = dialog_type != FILE_DIALOG_OPEN_FOLDER;
    void (^completion)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSModalResponseOK) {
            retained->Cancel();
            return;
        }
        std::vector<CefString> paths;
        for (NSURL *URL in panel.URLs) {
            paths.emplace_back(URL.path.UTF8String);
        }
        retained->Continue(paths);
    };
    if (host.window) {
        [panel beginSheetModalForWindow:host.window
                     completionHandler:completion];
    } else {
        [panel beginWithCompletionHandler:completion];
    }
    return true;
}

void BrowserClient::OnFindResult(CefRefPtr<CefBrowser> browser,
                                 int identifier,
                                 int count,
                                 const CefRect& selection_rect,
                                 int active_match_ordinal,
                                 bool final_update) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidUpdateFindMatchCount:count
                      activeMatchOrdinal:active_match_ordinal
                             finalUpdate:final_update];
    }
}

bool BrowserClient::GetAuthCredentials(
    CefRefPtr<CefBrowser> browser,
    const CefString& origin_url,
    bool is_proxy,
    const CefString& host,
    int port,
    const CefString& realm,
    const CefString& scheme,
    CefRefPtr<CefAuthCallback> callback) {
    CEF_REQUIRE_IO_THREAD();
    ChromiumBrowserHostView *host_view = host_;
    NSURL *URL = NSURLFromCef(origin_url);
    dispatch_async(dispatch_get_main_queue(), ^{
        [host_view cefDidRejectAuthenticationForURL:URL];
    });
    return false;
}

bool BrowserClient::OnCertificateError(CefRefPtr<CefBrowser> browser,
                                       cef_errorcode_t cert_error,
                                       const CefString& request_url,
                                       CefRefPtr<CefSSLInfo> ssl_info,
                                       CefRefPtr<CefCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    [host_ cefDidRejectCertificateError:cert_error
                                 forURL:NSURLFromCef(request_url)];
    return false;
}

bool BrowserClient::OnSelectClientCertificate(
    CefRefPtr<CefBrowser> browser,
    bool is_proxy,
    const CefString& host,
    int port,
    const X509CertificateList& certificates,
    CefRefPtr<CefSelectClientCertificateCallback> callback) {
    CEF_REQUIRE_UI_THREAD();
    [host_ cefDidRejectClientCertificateForHost:NSStringFromCef(host)
                                           port:port];
    callback->Select(nullptr);
    return true;
}

void BrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser,
                                  const CefString& title) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidChangeTitle:NSStringFromCef(title)];
    }
}

void BrowserClient::OnLoadingProgressChange(CefRefPtr<CefBrowser> browser,
                                            double progress) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidChangeProgress:progress];
    }
}

void BrowserClient::OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                                         bool is_loading,
                                         bool can_go_back,
                                         bool can_go_forward) {
    CEF_REQUIRE_UI_THREAD();
    if (!closing_ && IsCurrent(browser)) {
        [host_ cefDidChangeLoading:is_loading
                         canGoBack:can_go_back
                      canGoForward:can_go_forward];
    }
}

void BrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                ErrorCode error_code,
                                const CefString& error_text,
                                const CefString& failed_url) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !IsCurrent(browser) || !frame->IsMain()) {
        return;
    }
    NSString *URLString = NSStringFromCef(failed_url);
    NSURL *URL = [NSURL URLWithString:URLString];
    NSDictionary *details = URL
        ? @{@"ChromiumNetError": @(error_code),
            NSURLErrorFailingURLErrorKey: URL}
        : @{@"ChromiumNetError": @(error_code)};
    [host_ cefDidFail:ChromiumKitError(
                          ChromiumKitErrorNavigationFailed,
                          NSStringFromCef(error_text),
                          details)];
}

void BrowserClient::OnRenderProcessTerminated(
    CefRefPtr<CefBrowser> browser,
    TerminationStatus status,
    int error_code,
    const CefString& error_string) {
    CEF_REQUIRE_UI_THREAD();
    if (closing_ || !IsCurrent(browser)) {
        return;
    }
    ChromiumRendererTerminationStatus mapped =
        ChromiumRendererTerminationStatusAbnormal;
    switch (status) {
        case TS_PROCESS_WAS_KILLED:
            mapped = ChromiumRendererTerminationStatusKilled;
            break;
        case TS_PROCESS_CRASHED:
            mapped = ChromiumRendererTerminationStatusCrashed;
            break;
        case TS_PROCESS_OOM:
            mapped = ChromiumRendererTerminationStatusOutOfMemory;
            break;
        case TS_LAUNCH_FAILED:
            mapped = ChromiumRendererTerminationStatusLaunchFailed;
            break;
        case TS_INTEGRITY_FAILURE:
            mapped = ChromiumRendererTerminationStatusIntegrityFailure;
            break;
        default:
            break;
    }
    [host_ cefRendererTerminated:mapped];
}

void BrowserClient::Load(NSURL *URL) {
    CEF_REQUIRE_UI_THREAD();
    if (browser_ && !closing_) {
        browser_->GetMainFrame()->LoadURL(URL.absoluteString.UTF8String);
    }
}

void BrowserClient::Back() {
    if (browser_ && !closing_) browser_->GoBack();
}
void BrowserClient::Forward() {
    if (browser_ && !closing_) browser_->GoForward();
}
void BrowserClient::Reload() {
    if (browser_ && !closing_) browser_->Reload();
}
void BrowserClient::Stop() {
    if (browser_ && !closing_) browser_->StopLoad();
}
void BrowserClient::Focus() {
    if (!browser_ || closing_) return;
    browser_->GetHost()->SetFocus(true);
    NSView *view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
    [host_.window makeFirstResponder:view];
}
void BrowserClient::SetZoom(double level) {
    if (browser_ && !closing_) browser_->GetHost()->SetZoomLevel(level);
}
void BrowserClient::OpenDevTools() {
    CEF_REQUIRE_UI_THREAD();
    if (!browser_ || closing_) return;
    CefWindowInfo window_info;
    window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    browser_->GetHost()->ShowDevTools(window_info, this, settings, CefPoint());
}
void BrowserClient::CloseDevTools() {
    if (browser_ && !closing_) browser_->GetHost()->CloseDevTools();
}
void BrowserClient::Find(NSString *text,
                         bool forward,
                         bool match_case,
                         bool find_next) {
    if (browser_ && !closing_) {
        browser_->GetHost()->Find(text.UTF8String, forward, match_case,
                                  find_next);
    }
}
void BrowserClient::StopFinding(bool clear_selection) {
    if (browser_ && !closing_) {
        browser_->GetHost()->StopFinding(clear_selection);
    }
}
void BrowserClient::PrintPage() {
    if (!browser_ || closing_) return;
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector = @selector(chromiumBrowserHostViewShouldPrint:);
    if ([delegate respondsToSelector:selector] &&
        [delegate chromiumBrowserHostViewShouldPrint:host]) {
        browser_->GetHost()->Print();
    }
}
void BrowserClient::SavePage() {
    if (!browser_ || closing_) return;
    CefString page_url = browser_->GetMainFrame()->GetURL();
    NSURL *URL = NSURLFromCef(page_url);
    ChromiumBrowserHostView *host = host_;
    id<ChromiumBrowserHostViewDelegate> delegate = host.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:shouldSavePageURL:);
    if (URL && [delegate respondsToSelector:selector] &&
        [delegate chromiumBrowserHostView:host shouldSavePageURL:URL]) {
        browser_->GetHost()->StartDownload(page_url);
    }
}
bool BrowserClient::ExecuteJavaScript(NSString *script,
                                      NSURL *source_url,
                                      NSInteger line) {
    CEF_REQUIRE_UI_THREAD();
    if (!browser_ || closing_ || script.length == 0 || line < 1) {
        return false;
    }
    const char *source = source_url
        ? source_url.absoluteString.UTF8String
        : "pilot://chromium-runtime-probe";
    browser_->GetMainFrame()->ExecuteJavaScript(
        script.UTF8String,
        source,
        static_cast<int>(line));
    return true;
}

bool BrowserClient::SendMouseClick(NSPoint point) {
    CEF_REQUIRE_UI_THREAD();
    ChromiumBrowserHostView *host = host_;
    if (!browser_ || closing_ || host == nil ||
        !NSPointInRect(point, host.bounds)) {
        return false;
    }
    CefMouseEvent event;
    event.x = static_cast<int>(std::lround(point.x));
    event.y = static_cast<int>(
        std::lround(NSHeight(host.bounds) - point.y));
    event.modifiers = 0;
    browser_->GetHost()->SendMouseClickEvent(
        event, MBT_LEFT, false, 1);
    browser_->GetHost()->SendMouseClickEvent(
        event, MBT_LEFT, true, 1);
    return true;
}
void BrowserClient::Layout() {
    if (!browser_) return;
    ChromiumBrowserHostView *host = host_;
    NSView *view =
        CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser_->GetHost()->GetWindowHandle());
    view.frame = host.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

}  // namespace

@implementation ChromiumEngine

+ (ChromiumEngine *)shared {
    static ChromiumEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[ChromiumEngine alloc] initPrivate];
    });
    return engine;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _state = ChromiumEngineStateNotStarted;
        _shutdownCompletions = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isRunning {
    return self.state == ChromiumEngineStateInitializing ||
           self.state == ChromiumEngineStateRunning;
}

- (BOOL)isRuntimeAvailable {
    return YES;
}

- (NSUInteger)activeBrowserCount {
    return g_engine ? g_engine->ClientCount() : 0;
}

- (NSUInteger)messagePumpWatchdogWorkCount {
    return ExternalMessagePump::Shared().WatchdogWorkCount();
}

- (void)setExtensionDirectories:(NSArray<NSURL *> *)directories {
    // Must be set before start: CEF reads the command line once during
    // CefInitialize, and Chrome ties an unpacked extension's identity to the
    // absolute path it was loaded from.
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *directory in directories) {
        if (!directory.isFileURL) { continue; }
        NSString *path = directory.URLByStandardizingPath.path;
        // A comma separates entries in the switch value, so a path containing
        // one cannot be expressed and is dropped rather than silently splitting
        // into two bogus directories.
        if (path.length == 0 || [path containsString:@","]) { continue; }
        [paths addObject:path];
    }
    g_extension_load_paths =
        [[paths componentsJoinedByString:@","] UTF8String] ?: "";
}

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                            error:(NSError **)error {
    NSCAssert(NSThread.isMainThread, @"CEF must initialize on main");
    if (!profileDirectory.isFileURL) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInvalidProfileDirectory,
                @"The Chromium profile directory must be a file URL.", nil);
        }
        return NO;
    }
    if (self.state == ChromiumEngineStateInitializing ||
        self.state == ChromiumEngineStateRunning) {
        return YES;
    }
    if (self.state != ChromiumEngineStateNotStarted) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInitializationFailed,
                @"CEF cannot be restarted in this process.", nil);
        }
        return NO;
    }

    NSError *directoryError;
    if (![NSFileManager.defaultManager
            createDirectoryAtURL:profileDirectory
     withIntermediateDirectories:YES
                      attributes:nil
                           error:&directoryError]) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInvalidProfileDirectory,
                @"The Chromium profile directory could not be created.",
                @{NSUnderlyingErrorKey: directoryError});
        }
        return NO;
    }

    self.state = ChromiumEngineStateInitializing;
    g_engine = new EngineCore(self);
    if (!g_engine->Start(profileDirectory, error)) {
        EngineCore *failed_engine = g_engine;
        g_engine = nullptr;
        delete failed_engine;
        self.state = ChromiumEngineStateFailed;
        return NO;
    }
    return YES;
}

- (void)shutdown {
    [self shutdownWithCompletion:nil];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    NSCAssert(NSThread.isMainThread, @"CEF must shut down on main");
    if (completion) {
        [self.shutdownCompletions addObject:[completion copy]];
    }
    if (g_engine) {
        g_engine->Shutdown();
        return;
    }
    if (self.state == ChromiumEngineStateNotStarted) {
        self.state = ChromiumEngineStateShutDown;
    }
    [self chromiumDidFinishShutdown];
}

- (void)chromiumDidFinishShutdown {
    NSCAssert(NSThread.isMainThread, @"CEF shutdown completion requires main");
    self.state = ChromiumEngineStateShutDown;
    NSArray *completions = [self.shutdownCompletions copy];
    [self.shutdownCompletions removeAllObjects];
    for (void (^completion)(void) in completions) {
        completion();
    }
}

@end

@implementation ChromiumBrowserHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self initializeHost];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self initializeHost];
    return self;
}

- (void)initializeHost {
    _lifecycleState = ChromiumBrowserLifecycleStateCreating;
    _estimatedProgress = 0;
    _zoomLevel = 0;
    if (g_engine) {
        _chromiumToken = g_engine->AddHost(self);
    }
}

- (CefRefPtr<BrowserClient>)client {
    return g_engine ? g_engine->Client(self.chromiumToken) : nullptr;
}

- (void)loadURL:(NSURL *)URL {
    NSCAssert(NSThread.isMainThread, @"Browser commands require main");
    self.pendingURL = URL;
    if (!self.chromiumToken && g_engine) {
        self.chromiumToken = g_engine->AddHost(self);
    }
    if (CefRefPtr<BrowserClient> client = [self client]) client->Load(URL);
}
- (void)back {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Back();
}
- (void)forward {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Forward();
}
- (void)reload {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Reload();
}
- (void)stop {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Stop();
}
- (void)focusBrowser {
    if (CefRefPtr<BrowserClient> client = [self client]) client->Focus();
}
- (void)setZoom:(double)zoomLevel {
    self.zoomLevel = zoomLevel;
    if (CefRefPtr<BrowserClient> client = [self client]) client->SetZoom(zoomLevel);
}
- (void)openDevTools {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->OpenDevTools();
    }
}
- (void)findText:(NSString *)text
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->Find(text, forward, matchCase, findNext);
    }
}
- (void)stopFindingAndClearSelection:(BOOL)clearSelection {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->StopFinding(clearSelection);
    }
}
- (void)printPage {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->PrintPage();
    }
}
- (void)savePage {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->SavePage();
    }
}
- (BOOL)executeJavaScript:(NSString *)script
                sourceURL:(NSURL *)sourceURL
                     line:(NSInteger)line {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        return client->ExecuteJavaScript(script, sourceURL, line);
    }
    return NO;
}
- (BOOL)sendMouseClickAtPoint:(NSPoint)point {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        return client->SendMouseClick(point);
    }
    return NO;
}
- (void)closeDevTools {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->CloseDevTools();
    }
}
- (void)close {
    if (CefRefPtr<BrowserClient> client = [self client]) {
        client->Close(false);
    } else {
        [self cefDidClose];
    }
}

- (void)layout {
    [super layout];
    if (CefRefPtr<BrowserClient> client = [self client]) client->Layout();
}

- (void)dealloc {
    _delegate = nil;
    if (CefRefPtr<BrowserClient> client = [self client]) client->DetachHost();
}

- (void)cefDidCreate {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreating) return;
    self.lifecycleState = ChromiumBrowserLifecycleStateCreated;
    if ([self.delegate respondsToSelector:
            @selector(chromiumBrowserHostViewDidCreate:)]) {
        [self.delegate chromiumBrowserHostViewDidCreate:self];
    }
    NSURL *pending = self.pendingURL;
    self.pendingURL = nil;
    if (pending) [self loadURL:pending];
}

- (void)cefDidChangeURL:(NSURL *)URL {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.URL = URL;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeURL:)]) {
        [delegate chromiumBrowserHostView:self didChangeURL:URL];
    }
}
- (void)cefDidChangeTitle:(NSString *)title {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.title = title;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeTitle:)]) {
        [delegate chromiumBrowserHostView:self didChangeTitle:title];
    }
}
- (void)cefDidChangeLoading:(BOOL)loading
                  canGoBack:(BOOL)canGoBack
               canGoForward:(BOOL)canGoForward {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.loading = loading;
    self.canGoBack = canGoBack;
    self.canGoForward = canGoForward;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeLoading:)]) {
        [delegate chromiumBrowserHostView:self didChangeLoading:loading];
    }
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeCanGoBack:)]) {
        [delegate chromiumBrowserHostView:self didChangeCanGoBack:canGoBack];
    }
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeCanGoForward:)]) {
        [delegate chromiumBrowserHostView:self
                   didChangeCanGoForward:canGoForward];
    }
}
- (void)cefDidChangeProgress:(double)progress {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    self.estimatedProgress = progress;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeProgress:)]) {
        [delegate chromiumBrowserHostView:self didChangeProgress:progress];
    }
}
- (void)cefDidFail:(NSError *)error {
    if (self.lifecycleState == ChromiumBrowserLifecycleStateClosed) return;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:
                         didFailNavigationWithError:)]) {
        [delegate chromiumBrowserHostView:self
              didFailNavigationWithError:error];
    }
}
- (void)cefRendererTerminated:(ChromiumRendererTerminationStatus)status {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateCreated) return;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:
                         rendererTerminatedWithStatus:)]) {
        [delegate chromiumBrowserHostView:self
            rendererTerminatedWithStatus:status];
    }
}
- (void)cefDidUpdateFindMatchCount:(NSInteger)matchCount
                activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                       finalUpdate:(BOOL)finalUpdate {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didUpdateFindMatchCount:
                                              activeMatchOrdinal:finalUpdate:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
                 didUpdateFindMatchCount:matchCount
                      activeMatchOrdinal:activeMatchOrdinal
                             finalUpdate:finalUpdate];
    }
}
- (void)cefDidUpdateDownloadWithIdentifier:(NSUInteger)identifier
                                       URL:(NSURL *)URL
                         suggestedFilename:(NSString *)suggestedFilename
                             receivedBytes:(int64_t)receivedBytes
                                totalBytes:(int64_t)totalBytes
                           percentComplete:(NSInteger)percentComplete
                                     state:(ChromiumDownloadState)state {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didUpdateDownloadWithIdentifier:
                              URL:suggestedFilename:receivedBytes:totalBytes:
                              percentComplete:state:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
          didUpdateDownloadWithIdentifier:identifier
                                      URL:URL
                        suggestedFilename:suggestedFilename
                            receivedBytes:receivedBytes
                               totalBytes:totalBytes
                          percentComplete:percentComplete
                                    state:state];
    }
}
- (void)cefDidRejectAuthenticationForURL:(NSURL *)URL {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRejectAuthenticationForURL:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
            didRejectAuthenticationForURL:URL];
    }
}
- (void)cefDidRejectCertificateError:(NSInteger)errorCode
                              forURL:(NSURL *)URL {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:didRejectCertificateError:forURL:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
               didRejectCertificateError:errorCode
                                   forURL:URL];
    }
}
- (void)cefDidRejectClientCertificateForHost:(NSString *)host
                                        port:(NSInteger)port {
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    SEL selector =
        @selector(chromiumBrowserHostView:
                     didRejectClientCertificateForHost:port:);
    if ([delegate respondsToSelector:selector]) {
        [delegate chromiumBrowserHostView:self
            didRejectClientCertificateForHost:host
                                        port:port];
    }
}
- (void)cefWillClose {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateClosed) {
        self.lifecycleState = ChromiumBrowserLifecycleStateClosing;
    }
}
- (void)cefDidClose {
    if (self.closeDelivered) return;
    self.closeDelivered = YES;
    self.lifecycleState = ChromiumBrowserLifecycleStateClosed;
    self.loading = NO;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostViewDidClose:)]) {
        [delegate chromiumBrowserHostViewDidClose:self];
    }
}

@end

#else

@implementation ChromiumEngine

+ (ChromiumEngine *)shared {
    static ChromiumEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[ChromiumEngine alloc] initPrivate];
    });
    return engine;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) _state = ChromiumEngineStateNotStarted;
    return self;
}

- (BOOL)isRunning {
    return self.state == ChromiumEngineStateInitializing ||
           self.state == ChromiumEngineStateRunning;
}

- (BOOL)isRuntimeAvailable {
    return NO;
}

- (NSUInteger)activeBrowserCount {
    return 0;
}

- (NSUInteger)messagePumpWatchdogWorkCount {
    return 0;
}

- (void)setExtensionDirectories:(NSArray<NSURL *> *)directories {
    // The artifact-free bridge links no CEF, so there is nothing to load.
}

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                            error:(NSError **)error {
    if (!profileDirectory.isFileURL) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorInvalidProfileDirectory,
                @"The Chromium profile directory must be a file URL.", nil);
        }
        return NO;
    }
    self.state = ChromiumEngineStateFailed;
    if (error) *error = ChromiumKitUnavailableError();
    return NO;
}

- (void)shutdown {
    [self shutdownWithCompletion:nil];
}

- (void)shutdownWithCompletion:(void (^)(void))completion {
    self.state = ChromiumEngineStateShutDown;
    if (completion) completion();
}

- (void)chromiumDidFinishShutdown {
    self.state = ChromiumEngineStateShutDown;
}

@end

@implementation ChromiumBrowserHostView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) [self initializeUnavailableHost];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self initializeUnavailableHost];
    return self;
}
- (void)initializeUnavailableHost {
    _lifecycleState = ChromiumBrowserLifecycleStateCreating;
    _estimatedProgress = 0;
    _zoomLevel = 0;
}
- (void)loadURL:(NSURL *)URL {
    if (self.lifecycleState == ChromiumBrowserLifecycleStateClosed) return;
    self.URL = URL;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostView:didChangeURL:)]) {
        [delegate chromiumBrowserHostView:self didChangeURL:URL];
    }
    [self cefDidFail:ChromiumKitUnavailableError()];
}
- (void)back { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)forward { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)reload { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)stop { self.loading = NO; }
- (void)focusBrowser {}
- (void)setZoom:(double)zoomLevel { self.zoomLevel = zoomLevel; }
- (void)openDevTools { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)closeDevTools {}
- (void)findText:(NSString *)text
         forward:(BOOL)forward
       matchCase:(BOOL)matchCase
        findNext:(BOOL)findNext {
    [self cefDidFail:ChromiumKitUnavailableError()];
}
- (void)stopFindingAndClearSelection:(BOOL)clearSelection {}
- (void)printPage { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (void)savePage { [self cefDidFail:ChromiumKitUnavailableError()]; }
- (BOOL)executeJavaScript:(NSString *)script
                sourceURL:(NSURL *)sourceURL
                     line:(NSInteger)line {
    return NO;
}
- (BOOL)sendMouseClickAtPoint:(NSPoint)point { return NO; }
- (void)close { [self cefDidClose]; }
- (void)cefDidCreate {}
- (void)cefDidChangeURL:(NSURL *)URL {}
- (void)cefDidChangeTitle:(NSString *)title {}
- (void)cefDidChangeLoading:(BOOL)loading
                  canGoBack:(BOOL)canGoBack
               canGoForward:(BOOL)canGoForward {}
- (void)cefDidChangeProgress:(double)progress {}
- (void)cefDidFail:(NSError *)error {
    if (self.lifecycleState != ChromiumBrowserLifecycleStateClosed) {
        id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:
                @selector(chromiumBrowserHostView:
                             didFailNavigationWithError:)]) {
            [delegate chromiumBrowserHostView:self
                  didFailNavigationWithError:error];
        }
    }
}
- (void)cefRendererTerminated:(ChromiumRendererTerminationStatus)status {}
- (void)cefDidUpdateFindMatchCount:(NSInteger)matchCount
                activeMatchOrdinal:(NSInteger)activeMatchOrdinal
                       finalUpdate:(BOOL)finalUpdate {}
- (void)cefDidUpdateDownloadWithIdentifier:(NSUInteger)identifier
                                       URL:(NSURL *)URL
                         suggestedFilename:(NSString *)suggestedFilename
                             receivedBytes:(int64_t)receivedBytes
                                totalBytes:(int64_t)totalBytes
                           percentComplete:(NSInteger)percentComplete
                                     state:(ChromiumDownloadState)state {}
- (void)cefDidRejectAuthenticationForURL:(NSURL *)URL {}
- (void)cefDidRejectCertificateError:(NSInteger)errorCode
                              forURL:(NSURL *)URL {}
- (void)cefDidRejectClientCertificateForHost:(NSString *)host
                                        port:(NSInteger)port {}
- (void)cefWillClose {
    self.lifecycleState = ChromiumBrowserLifecycleStateClosing;
}
- (void)cefDidClose {
    if (self.closeDelivered) return;
    self.closeDelivered = YES;
    self.lifecycleState = ChromiumBrowserLifecycleStateClosed;
    id<ChromiumBrowserHostViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:
            @selector(chromiumBrowserHostViewDidClose:)]) {
        [delegate chromiumBrowserHostViewDidClose:self];
    }
}

@end

#endif
