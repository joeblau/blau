import AppKit
import Foundation

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

    /// Injected at document end on every frame. Guarded so re-injection (SPA
    /// navigations, reloads) is harmless; `window.__pilotAnnotate.setEnabled`
    /// toggles it from Swift.
    static let userScript = """
    (function () {
      if (window.__pilotAnnotate) return;
      var enabled = false, highlight = null, box = null, current = null;

      function ensureHighlight() {
        if (highlight) return highlight;
        highlight = document.createElement('div');
        highlight.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;border:2px solid #3b82f6;background:rgba(59,130,246,0.12);border-radius:3px;display:none;';
        document.documentElement.appendChild(highlight);
        return highlight;
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
        if (!el) return;
        var r = el.getBoundingClientRect();
        var h = ensureHighlight();
        h.style.display = 'block';
        h.style.left = r.left + 'px';
        h.style.top = r.top + 'px';
        h.style.width = r.width + 'px';
        h.style.height = r.height + 'px';
      }

      function onMove(e) {
        if (!enabled) return;
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === highlight || (box && box.contains(el))) return;
        current = el;
        positionHighlight(el);
      }

      // Keep the highlight glued to its element while the page scrolls; the box
      // is position:fixed so it stays put on its own.
      function onScroll() {
        if (!enabled) return;
        if (highlight && highlight.style.display !== 'none' && current && current.isConnected) {
          positionHighlight(current);
        }
      }

      function onClick(e) {
        if (!enabled) return;
        if (box && box.contains(e.target)) return;
        e.preventDefault();
        e.stopPropagation();
        showBox(current || e.target);
      }

      function removeBox() { if (box) { box.remove(); box = null; } }

      function showBox(el) {
        removeBox();
        var r = el.getBoundingClientRect();
        box = document.createElement('div');
        box.style.cssText = 'position:fixed;z-index:2147483647;left:' + Math.max(8, Math.min(r.left, window.innerWidth - 320)) + 'px;top:' + Math.min(r.bottom + 6, window.innerHeight - 170) + 'px;width:300px;background:#1c1c1e;color:#fff;border:1px solid #3b82f6;border-radius:10px;padding:10px;box-shadow:0 8px 30px rgba(0,0,0,0.55);font:13px -apple-system,system-ui;';
        var close = document.createElement('button');
        close.textContent = '×';
        close.title = 'Dismiss';
        close.style.cssText = 'position:absolute;top:4px;right:6px;width:20px;height:20px;line-height:18px;text-align:center;background:transparent;color:#8e8e93;border:none;border-radius:4px;font-size:17px;cursor:pointer;padding:0;';
        close.addEventListener('click', function () { removeBox(); if (highlight) highlight.style.display = 'none'; });
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
          else if (ev.key === 'Escape') { removeBox(); }
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
            url: document.location.href
          };
          removeBox();
          if (highlight) highlight.style.display = 'none';
          window.webkit.messageHandlers.pilotAnnotate.postMessage(payload);
        });
      }

      function setEnabled(v) {
        enabled = !!v;
        document.documentElement.style.cursor = enabled ? 'crosshair' : '';
        if (!enabled) { removeBox(); if (highlight) highlight.style.display = 'none'; }
      }

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);
      document.addEventListener('scroll', onScroll, true);
      window.addEventListener('resize', onScroll, true);
      window.__pilotAnnotate = { setEnabled: setEnabled };
    })();
    """

    /// JS to push the current enabled state into the page (after toggle / load).
    static func setEnabledScript(_ enabled: Bool) -> String {
        "window.__pilotAnnotate && window.__pilotAnnotate.setEnabled(\(enabled))"
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
            "Page URL: \(singleLine(url))",
            "Element selector: \(singleLine(selector))",
            "Element rect: x=\(rectX) y=\(rectY) w=\(rectW) h=\(rectH) (CSS px, viewport coords)",
            "Element HTML: \(html)",
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
