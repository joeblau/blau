# TODOS

Follow-ups captured from `/plan-eng-review` on 2026-04-16 for the iOS simulator tab feature (native CoreSimulator SPI path). Each item has enough context to be picked up cold in 3 months.

---

## Multi-touch via NSGestureRecognizer (Phase 2)

- **What:** Bridge trackpad pinch/rotate/pan gestures to iOS multi-touch HID events in the simulator pane.
- **Why:** MVP only supports Option+drag pinch (Apple Simulator.app convention). Real apps test with native trackpad gestures. Photo viewers, maps, and modern gesture-driven UIs can't be properly exercised without it.
- **Pros:** Feature parity with Apple's Simulator.app for gesture testing. Makes Pilot usable for QA on gesture-heavy apps.
- **Cons:** Two-finger coordinate translation is fiddly. `NSGestureRecognizer.magnification` gives scale delta, not two touch points — have to synthesize both touch coordinates. Multi-touch HID event format in CoreSimulator is undocumented; study fb-idb's multi-touch code.
- **Context:** MVP's `SimulatorInputBridge` handles single-touch HID via `SimDeviceIO.sendHIDEvent`. Phase 2 adds a `GestureRecognizerDelegate` on `SimulatorPaneView` that emits synchronized pairs of HID events for simulated finger positions. fb-idb has reference implementation in `FBSimulatorHIDEvent`.
- **Depends on / blocked by:** Phase 1 MVP shipped.
- **Effort:** ~6-10h CC.

---

## Drag-drop .app / .ipa install (Phase 1b)

- **What:** Accept file drops (`.app` bundle or `.ipa`) onto a simulator pane. Install the app via `SimDevice.installApplication` SPI. Show progress + success/error states in-pane.
- **Why:** Building in Xcode, then manually dragging to Simulator.app, then copying bundle ID to launch — is slow. Drag-drop install collapses that to one step.
- **Pros:** Huge ergonomics win for the primary dev loop Pilot targets. Turns sim pane into a real development tool rather than a passive viewer.
- **Cons:** Install errors have nuanced states (code signing, architecture mismatch, disk space). UX has to surface each meaningfully. .ipa requires unzip + bundle extraction.
- **Context:** Phase 1 MVP has a bootable sim and visible framebuffer. Phase 1b adds `onDrop` modifier on `SimulatorPaneView` → `SimulatorDevice.install(url:)` → `SimulatorInstallError` typed cases → pane banner UI. Apple uses `NSItemProvider` for file drops; extract `fileURL` and branch on extension.
- **Depends on / blocked by:** Phase 1 MVP shipped (sim pane visible and usable).
- **Effort:** ~3-5h CC.

---

## Extract BrowserState out of Workspace.swift

- **What:** Move `BrowserState` @Model (currently `Workspace.swift:91-143`) to its own file `apple/Sources/Pilot/BrowserState.swift`. Mirror the split pattern being established for `SimulatorState` in `apple/Sources/Pilot/Simulator/SimulatorState.swift`.
- **Why:** `Workspace.swift` is 637 lines today. Adding `SimulatorState` inline would push it toward 800. The file already mixes the Workspace model, Pane model, BrowserState model, and pane-layout logic — too many concerns for one file.
- **Pros:** Clear ownership (each @Model in its own file). Easier to review SwiftData schema changes in isolation. Matches the Simulator/ dir convention.
- **Cons:** Touching an existing model file that's already working. Minor import churn elsewhere.
- **Context:** `BrowserState` is at `apple/Sources/Pilot/Workspace.swift:91-143`. References are in `WorkspaceView.swift:619-751` (BrowserPaneView) and the Pane relationship declaration at `Workspace.swift:159-160`. Move the @Model class only; the `Pane.browserState` relationship stays in Workspace.swift (SwiftData relationships must be on the owning model).
- **Depends on / blocked by:** Not blocked. Could land before or after the simulator feature. Best landed before — sets the pattern.
- **Effort:** ~1h CC.

---

## Add .github/workflows/pilot.yml for PilotTests CI

- **What:** GitHub Actions workflow that builds Pilot and runs the PilotTests target on `push` and `pull_request` for paths matching `apple/**`. Runs unit tests only (excludes the `.integration` tag since the CI runner has no Xcode-installed simulators).
- **Why:** No macOS CI for Pilot exists today. The only workflow in `.github/workflows/` is `deploy.yml` for the web landing page. Regressions in Pilot are caught only by local developer testing. Adding CI closes the loop.
- **Pros:** Pane.init regression tests (R1, R2, R3) run automatically. SwiftData schema drift caught in PRs. Sets the gate for future contributors.
- **Cons:** macOS GitHub runners cost more (~10x Linux time), runs slower (~3-5 min per workflow). Integration tier can't run in CI because GitHub runners don't boot real iOS simulators reliably; manual-only tier stays manual.
- **Context:** PilotTests target is added as part of the simulator feature plan. After it exists, the workflow uses `xcodebuild test -scheme PilotTests -destination "platform=macOS"` with a filter to exclude `.integration`-tagged tests. Example workflow structure: `jobs.test` on `macos-15`, `xcodegen generate` first, then xcodebuild test.
- **Depends on / blocked by:** PilotTests target must exist (part of simulator feature plan).
- **Effort:** ~2h CC (mostly iteration on the YAML).
