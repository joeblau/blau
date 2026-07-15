import AppKit
import Foundation
import WebKit

/// "Browser Annotate" — point at a web element, describe a change, and dispatch
/// it (screenshot + element context + instruction) to the agent in a terminal.
///
/// The hover-highlight, click-to-select, the text box, and the Send button all
/// live as an injected in-page overlay (so there's no Swift↔web coordinate
/// math); the only Swift↔web boundary is the single `send` message. On send,
/// Swift screenshots the page, composes a prompt, and reuses Pilot's existing
/// `.pilotSendIssuePrompt` path (paste + Enter into the active terminal).
enum BrowserAnnotate {
    /// WKScriptMessageHandler name + the JS toggle entry point.
    static let messageName = "pilotAnnotate"
    @MainActor static let contentWorld = WKContentWorld.world(name: "PilotBrowserAnnotate")
    static let grantLifetime: TimeInterval = 120

    struct MessagePayload: Equatable {
        let instruction: String
        let url: String
        let selector: String
        let outerHTML: String
        let selectionID: String
        let bridgeToken: String
        let rectX: Int
        let rectY: Int
        let rectW: Int
        let rectH: Int

        static func parse(_ body: Any) -> MessagePayload? {
            guard let body = body as? [String: Any],
                  Set(body.keys) == [
                      "action", "instruction", "url", "selector", "outerHTML",
                      "selectionID", "bridgeToken", "rect",
                  ],
                  body["action"] as? String == "send",
                  let instruction = boundedString(body["instruction"], max: 2_000, allowEmpty: false),
                  let url = boundedString(body["url"], max: 2_048, allowEmpty: false),
                  let selector = boundedString(body["selector"], max: 2_048, allowEmpty: true),
                  let outerHTML = boundedString(body["outerHTML"], max: 8_192, allowEmpty: true),
                  let selectionID = boundedString(body["selectionID"], max: 128, allowEmpty: false),
                  let bridgeToken = boundedString(body["bridgeToken"], max: 128, allowEmpty: false),
                  let rect = body["rect"] as? [String: Any],
                  Set(rect.keys) == ["x", "y", "w", "h"],
                  let x = coordinate(rect["x"], allowsNegative: true),
                  let y = coordinate(rect["y"], allowsNegative: true),
                  let width = coordinate(rect["w"], allowsNegative: false),
                  let height = coordinate(rect["h"], allowsNegative: false) else { return nil }
            return MessagePayload(
                instruction: instruction,
                url: url,
                selector: selector,
                outerHTML: outerHTML,
                selectionID: selectionID,
                bridgeToken: bridgeToken,
                rectX: x,
                rectY: y,
                rectW: width,
                rectH: height
            )
        }

        private static func boundedString(_ value: Any?, max: Int, allowEmpty: Bool) -> String? {
            guard let string = value as? String,
                  string.utf8.count <= max,
                  allowEmpty || !string.isEmpty else { return nil }
            return string
        }

        private static func coordinate(_ value: Any?, allowsNegative: Bool) -> Int? {
            guard let number = value as? NSNumber else { return nil }
            let double = number.doubleValue
            guard double.isFinite, abs(double) <= 1_000_000,
                  allowsNegative || double >= 0 else { return nil }
            return Int(double.rounded())
        }
    }

    struct BridgeGrant {
        let token: String
        let navigationURL: String
        let expiresAt: Date
        private(set) var consumed = false

        mutating func consume(_ payload: MessagePayload, currentURL: String, now: Date = Date()) -> Bool {
            guard !consumed,
                  now < expiresAt,
                  payload.bridgeToken == token,
                  payload.url == navigationURL,
                  currentURL == navigationURL else { return false }
            consumed = true
            return true
        }
    }

    /// A send captures its terminal before the asynchronous WebKit snapshot
    /// starts. Keeping that target in this value prevents a later pane/workspace
    /// click from silently rerouting the prompt when the snapshot completes.
    struct DispatchContext {
        let targetPaneID: UUID?

        func notificationUserInfo(prompt: String) -> [AnyHashable: Any] {
            [
                BrowserAnnotate.promptUserInfoKey: prompt,
                // Preserve the distinction between an explicitly captured
                // "no terminal" and a legacy notification with no routing
                // metadata. The former must beep, not fall through to whichever
                // terminal happens to become active a moment later.
                BrowserAnnotate.targetPaneIDUserInfoKey: targetPaneID?.uuidString ?? NSNull(),
            ]
        }
    }

    static let promptUserInfoKey = "prompt"
    static let targetPaneIDUserInfoKey = "targetPaneID"

    static func hasCapturedTarget(in userInfo: [AnyHashable: Any]?) -> Bool {
        userInfo?[targetPaneIDUserInfoKey] != nil
    }

    static func targetPaneID(in userInfo: [AnyHashable: Any]?) -> UUID? {
        guard let value = userInfo?[targetPaneIDUserInfoKey] else { return nil }
        if let id = value as? UUID { return id }
        if let raw = value as? String { return UUID(uuidString: raw) }
        return nil
    }

    /// Injected at document end on every frame. Guarded so re-injection (SPA
    /// navigations, reloads) is harmless; `window.__pilotAnnotate.setEnabled`
    /// toggles it from Swift.
    static let userScript = """
    (function () {
      if (window.__pilotAnnotate) return;
      var initiallyEnabled = !!window.__pilotAnnotateDesiredEnabled;
      var enabled = false;
      var highlight = null, cursorStyle = null, box = null;
      var hovered = null, selected = null, sending = false;
      var selectionID = null, sendingID = null;
      var bridgeToken = null, selectionBridgeToken = null;
      var fallbackSelectionSequence = 0;

      function ensureCursorStyle() {
        if (cursorStyle) return;
        cursorStyle = document.createElement('style');
        cursorStyle.setAttribute('data-pilot-annotate-cursor', '');
        cursorStyle.textContent = 'html.__pilot-lasso-active, html.__pilot-lasso-active body, html.__pilot-lasso-active body * { cursor: crosshair !important; } html.__pilot-lasso-active [data-pilot-annotate-box], html.__pilot-lasso-active [data-pilot-annotate-box] * { cursor: default !important; } html.__pilot-lasso-active [data-pilot-annotate-box] textarea { cursor: text !important; } html.__pilot-lasso-active [data-pilot-annotate-box] button { cursor: pointer !important; }';
        document.documentElement.appendChild(cursorStyle);
      }

      function ensureHighlight() {
        if (highlight) return highlight;
        highlight = document.createElement('div');
        highlight.setAttribute('data-pilot-annotate-highlight', '');
        highlight.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;box-sizing:border-box;border:2px solid #3b82f6;background:rgba(59,130,246,0.12);border-radius:3px;display:none;';
        document.documentElement.appendChild(highlight);
        return highlight;
      }

      function isPilotUI(el) {
        return !el || el === highlight || (box && (el === box || box.contains(el)));
      }

      function eventElement(e) {
        var path = typeof e.composedPath === 'function' ? e.composedPath() : [];
        for (var i = 0; i < path.length; i++) {
          var node = path[i];
          if (node && node.nodeType === 1 && !isPilotUI(node)) return node;
        }
        var fallback = document.elementFromPoint(e.clientX, e.clientY);
        return isPilotUI(fallback) ? null : fallback;
      }

      function makeSelectionID() {
        // IDs must remain unique across navigations. A snapshot from the prior
        // document can finish after the new page has already made a selection;
        // a document-local counter would let that stale completion clear it.
        if (window.crypto && typeof window.crypto.randomUUID === 'function') {
          return window.crypto.randomUUID();
        }
        fallbackSelectionSequence += 1;
        return Date.now().toString(36) + '-' + fallbackSelectionSequence.toString(36) + '-' + Math.random().toString(36).slice(2);
      }

      function cssPath(el) {
        if (!el || el.nodeType !== 1) return '';
        if (el.id) return '#' + CSS.escape(el.id);
        var parts = [];
        while (el && el.nodeType === 1 && parts.length < 6) {
          var sel = el.tagName.toLowerCase();
          if (el.classList && el.classList.length) {
            sel += '.' + Array.prototype.slice.call(el.classList, 0, 2).map(function (c) { return CSS.escape(c); }).join('.');
          }
          var parent = el.parentElement;
          if (parent) {
            var sibs = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
            if (sibs.length > 1) sel += ':nth-of-type(' + (sibs.indexOf(el) + 1) + ')';
          }
          parts.unshift(sel);
          el = parent;
        }
        return parts.join(' > ');
      }

      function positionHighlight(el) {
        if (!el || !el.isConnected) { hideHighlight(); return; }
        var r = el.getBoundingClientRect();
        var h = ensureHighlight();
        h.style.display = 'block';
        h.style.left = r.left + 'px';
        h.style.top = r.top + 'px';
        h.style.width = r.width + 'px';
        h.style.height = r.height + 'px';
        h.style.borderColor = selected === el ? '#0a84ff' : '#3b82f6';
        h.style.background = selected === el ? 'rgba(10,132,255,0.18)' : 'rgba(59,130,246,0.12)';
        h.style.boxShadow = selected === el ? '0 0 0 1px rgba(255,255,255,0.8)' : 'none';
      }

      function hideHighlight() {
        if (highlight) highlight.style.display = 'none';
      }

      function onMove(e) {
        if (!enabled || selected || sending) return;
        var el = eventElement(e);
        if (!el) return;
        hovered = el;
        positionHighlight(el);
      }

      // Keep the highlight glued to its element while the page scrolls; the box
      // is position:fixed so it stays put on its own.
      function onScroll() {
        if (!enabled) return;
        var target = selected || hovered;
        if (target && target.isConnected) {
          positionHighlight(target);
        } else {
          if (selected) clearSelection();
          hovered = null;
          hideHighlight();
        }
      }

      function blockPageEvent(e) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }

      function onPointerDown(e) {
        if (!enabled || (box && box.contains(e.target))) return;
        var target = eventElement(e);
        blockPageEvent(e);
        if (sending) return;
        if (target) showBox(target);
      }

      // The pointerdown owns selection. Suppress the compatibility click so
      // the page cannot activate a link/button after the lasso has selected it.
      function onClick(e) {
        if (!enabled || (box && box.contains(e.target))) return;
        blockPageEvent(e);
      }

      function removeBox() { if (box) { box.remove(); box = null; } }

      function clearSelection() {
        removeBox();
        hovered = null;
        selected = null;
        sending = false;
        selectionID = null;
        sendingID = null;
        selectionBridgeToken = null;
        hideHighlight();
      }

      function showBox(el) {
        removeBox();
        selectionID = makeSelectionID();
        selectionBridgeToken = bridgeToken;
        selected = el;
        hovered = el;
        positionHighlight(el);
        var r = el.getBoundingClientRect();
        box = document.createElement('div');
        box.setAttribute('data-pilot-annotate-box', '');
        box.style.cssText = 'position:fixed;z-index:2147483647;left:' + Math.max(8, Math.min(r.left, window.innerWidth - 320)) + 'px;top:' + Math.min(r.bottom + 6, window.innerHeight - 170) + 'px;width:300px;background:#1c1c1e;color:#fff;border:1px solid #3b82f6;border-radius:10px;padding:10px;box-shadow:0 8px 30px rgba(0,0,0,0.55);font:13px -apple-system,system-ui;';
        var close = document.createElement('button');
        close.textContent = '×';
        close.title = 'Dismiss';
        close.style.cssText = 'position:absolute;top:4px;right:6px;width:20px;height:20px;line-height:18px;text-align:center;background:transparent;color:#8e8e93;border:none;border-radius:4px;font-size:17px;cursor:pointer;padding:0;';
        close.addEventListener('click', clearSelection);
        box.appendChild(close);
        var ta = document.createElement('textarea');
        ta.placeholder = 'Describe what you want to happen…';
        ta.style.cssText = 'width:100%;height:62px;background:#000;color:#fff;border:1px solid #333;border-radius:6px;padding:6px;resize:none;box-sizing:border-box;font:13px -apple-system,system-ui;';
        box.appendChild(ta);
        var hint = document.createElement('div');
        hint.textContent = 'Press Enter, click a terminal, then Send';
        hint.style.cssText = 'color:#8e8e93;font-size:11px;margin-top:6px;';
        box.appendChild(hint);
        var send = document.createElement('button');
        send.textContent = 'Send';
        send.style.cssText = 'display:none;margin-top:8px;width:100%;background:#3b82f6;color:#fff;border:none;border-radius:6px;padding:7px;font:600 13px -apple-system,system-ui;cursor:pointer;';
        box.appendChild(send);
        document.documentElement.appendChild(box);
        ta.focus();

        ta.addEventListener('keydown', function (ev) {
          if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); send.style.display = 'block'; hint.textContent = 'Click a terminal, then Send'; }
          else if (ev.key === 'Escape') { clearSelection(); }
        });
        send.addEventListener('click', function () {
          // Re-read geometry now — the page may have scrolled or reflowed since
          // the box opened, so the captured `r` could be stale.
          var live = el.isConnected ? el.getBoundingClientRect() : r;
          var payload = {
            action: 'send',
            instruction: ta.value,
            selector: cssPath(el),
            outerHTML: (el.outerHTML || '').slice(0, 8000),
            rect: { x: live.left, y: live.top, w: live.width, h: live.height },
            selectionID: selectionID,
            bridgeToken: selectionBridgeToken,
            url: document.location.href
          };
          // Keep the selected outline visible while Swift snapshots the page.
          // `finishSend` clears it only after the image has been captured.
          sending = true;
          sendingID = selectionID;
          removeBox();
          selected = el;
          positionHighlight(el);
          try {
            window.webkit.messageHandlers.pilotAnnotate.postMessage(payload);
          } catch (_) {
            finishSend(selectionID);
          }
        });
      }

      function setEnabled(v, token) {
        window.__pilotAnnotateDesiredEnabled = !!v;
        enabled = !!v;
        bridgeToken = enabled && typeof token === 'string' ? token : null;
        ensureCursorStyle();
        document.documentElement.classList.toggle('__pilot-lasso-active', enabled);
        if (!enabled) clearSelection();
      }

      function finishSend(completedSelectionID) {
        // A stale snapshot must not clear a newer selection made after a rapid
        // off/on toggle. Only the send that owns the outline may release it.
        if (completedSelectionID !== sendingID) return;
        removeBox();
        hovered = null;
        selected = null;
        sending = false;
        selectionID = null;
        sendingID = null;
        selectionBridgeToken = null;
        hideHighlight();
      }

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('pointerdown', onPointerDown, true);
      document.addEventListener('click', onClick, true);
      document.addEventListener('scroll', onScroll, true);
      window.addEventListener('resize', onScroll, true);
      window.__pilotAnnotate = { setEnabled: setEnabled, finishSend: finishSend };
      setEnabled(initiallyEnabled, null);
    })();
    """

    /// JS to push the current enabled state into the page (after toggle / load).
    static func setEnabledScript(_ enabled: Bool, token: String? = nil) -> String {
        let tokenData = try? JSONEncoder().encode(token)
        let tokenLiteral = tokenData.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return """
        window.__pilotAnnotateDesiredEnabled = \(enabled);
        window.__pilotAnnotate && window.__pilotAnnotate.setEnabled(\(enabled), \(tokenLiteral));
        """
    }

    /// Clears the locked selection only after WebKit has captured its outline.
    static func finishSendScript(selectionID: String) -> String {
        let data = try? JSONEncoder().encode(selectionID)
        let literal = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "window.__pilotAnnotate && window.__pilotAnnotate.finishSend(\(literal))"
    }

    @MainActor
    static func evaluate(_ script: String, in webView: WKWebView) {
        webView.evaluateJavaScript(script, in: nil, in: contentWorld) { _ in }
    }

    /// Collapse control chars (newlines, tabs, ESC sequences) + whitespace runs
    /// to single spaces. The element HTML/selector/URL/instruction are
    /// page-controlled, so this neutralizes newline command-injection and
    /// terminal-escape injection before any of it reaches a terminal.
    private static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .controlCharacters).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Compose the agent prompt from the captured element + screenshot.
    ///
    /// The result is a *single line* (no embedded newlines): it's delivered to
    /// the terminal by typing the text and then pressing Enter once, so a
    /// newline anywhere in the prompt would submit it early — and, with
    /// page-controlled content, would execute the tail as a separate command.
    /// Every field is run through `singleLine`, and the sections are joined with
    /// " | " so one Enter sends exactly one message to the agent.
    static func buildPrompt(instruction: String, url: String, selector: String,
                            outerHTML: String, rectX: Int, rectY: Int, rectW: Int, rectH: Int,
                            screenshotPath: String?) -> String {
        let rawHTML = singleLine(outerHTML)
        let html = rawHTML.count > 2000 ? String(rawHTML.prefix(2000)) + " …(truncated)" : rawHTML
        var parts = [
            "[Pilot Browser Annotate]",
            "Instruction: \(singleLine(instruction))",
            "BEGIN UNTRUSTED PAGE CONTEXT",
            "Page URL: \(singleLine(url))",
            "Element selector: \(singleLine(selector))",
            "Element rect: x=\(rectX) y=\(rectY) w=\(rectW) h=\(rectH) (CSS px, viewport coords)",
            "Element HTML: \(html)",
            "END UNTRUSTED PAGE CONTEXT",
        ]
        if let screenshotPath { parts.append("Screenshot saved at: \(singleLine(screenshotPath))") }
        parts.append("Please make the requested change. The screenshot shows the page; the selector and HTML identify the exact element.")
        return parts.joined(separator: " | ")
    }

    /// Write a page snapshot to a per-user temp PNG; returns its absolute path.
    /// Snapshots live in a private 0700 subdirectory (not world-readable like
    /// bare `/tmp`) and stale ones are swept on each write so they don't pile up.
    static func writeScreenshot(_ image: NSImage?) -> String? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-annotate", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        sweepStale(in: dir)
        let url = dir.appendingPathComponent("annotate-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch { return nil }
    }

    /// Delete snapshots older than an hour — the agent reads them within
    /// seconds of dispatch, so anything lingering is abandoned.
    private static func sweepStale(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date(timeIntervalSinceNow: -3600)
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
