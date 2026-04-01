"""设置窗口 — 使用 PyObjC WKWebView 原生窗口渲染 HTML

在 rumps menubar app 中直接打开一个 NSWindow + WKWebView，
无需启动 HTTP server 或调用 webbrowser.open()。
"""

import json
import logging
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

CONFIG_DIR = Path(__file__).parent.parent / "config"

try:
    import AppKit
    import Foundation
    import WebKit
    import objc

    HAS_WEBKIT = True
except ImportError:
    HAS_WEBKIT = False
    logger.warning("pyobjc-framework-WebKit not available, settings will use fallback")


HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>VibeKeyboard Settings</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
    background: #1a1a2e;
    color: #e0e0e0;
    padding: 24px;
    max-width: 500px;
    margin: 0 auto;
  }
  h1 {
    font-size: 22px;
    font-weight: 600;
    color: #fff;
    margin-bottom: 20px;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .section {
    background: rgba(255,255,255,0.06);
    border-radius: 12px;
    padding: 16px;
    margin-bottom: 16px;
    border: 1px solid rgba(255,255,255,0.08);
  }
  .section-title {
    font-size: 13px;
    font-weight: 600;
    color: #8b8fa3;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    margin-bottom: 12px;
  }
  .row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 0;
  }
  .row + .row { border-top: 1px solid rgba(255,255,255,0.06); }
  .row label { font-size: 14px; color: #c8c8d0; }
  .row input[type="number"] {
    width: 70px; padding: 6px 10px; border-radius: 8px;
    border: 1px solid rgba(255,255,255,0.15);
    background: rgba(255,255,255,0.08);
    color: #fff; font-size: 14px; text-align: center; outline: none;
  }
  .row input[type="number"]:focus { border-color: #6c5ce7; box-shadow: 0 0 0 3px rgba(108,92,231,0.2); }
  .toggle { position: relative; width: 44px; height: 24px; cursor: pointer; }
  .toggle input { display: none; }
  .toggle .slider {
    position: absolute; inset: 0; background: rgba(255,255,255,0.15);
    border-radius: 12px; transition: 0.2s;
  }
  .toggle .slider:before {
    content: ""; position: absolute; width: 18px; height: 18px;
    left: 3px; top: 3px; background: #fff; border-radius: 50%; transition: 0.2s;
  }
  .toggle input:checked + .slider { background: #6c5ce7; }
  .toggle input:checked + .slider:before { transform: translateX(20px); }
  .hotword-area { display: flex; gap: 8px; margin-bottom: 10px; }
  .hotword-area input {
    flex: 1; padding: 8px 12px; border-radius: 8px;
    border: 1px solid rgba(255,255,255,0.15);
    background: rgba(255,255,255,0.08); color: #fff; font-size: 14px; outline: none;
  }
  .hotword-area input:focus { border-color: #6c5ce7; box-shadow: 0 0 0 3px rgba(108,92,231,0.2); }
  .hotword-area input::placeholder { color: #666; }
  .btn {
    padding: 8px 16px; border-radius: 8px; border: none;
    font-size: 13px; font-weight: 500; cursor: pointer; transition: 0.15s;
  }
  .btn-add { background: #6c5ce7; color: #fff; }
  .btn-add:hover { background: #5a4bd1; }
  .tags { display: flex; flex-wrap: wrap; gap: 6px; min-height: 32px; }
  .tag {
    display: inline-flex; align-items: center; gap: 4px;
    padding: 4px 10px; background: rgba(108,92,231,0.2);
    border: 1px solid rgba(108,92,231,0.3); border-radius: 16px;
    font-size: 13px; color: #c8b6ff;
  }
  .tag .del { cursor: pointer; opacity: 0.6; font-size: 15px; }
  .tag .del:hover { opacity: 1; color: #ff6b6b; }
  .empty-hint { font-size: 13px; color: #555; font-style: italic; }
  .save-bar { display: flex; justify-content: flex-end; gap: 12px; align-items: center; margin-top: 8px; }
  .btn-save {
    background: linear-gradient(135deg, #6c5ce7, #a855f7); color: #fff;
    padding: 10px 28px; font-size: 14px; border-radius: 10px;
  }
  .btn-save:hover { opacity: 0.9; }
  .status { font-size: 13px; color: #6c5ce7; opacity: 0; transition: 0.3s; }
  .status.show { opacity: 1; }
</style>
</head>
<body>
<h1>VibeKeyboard Settings</h1>

<div class="section">
  <div class="section-title">Recording</div>
  <div class="row"><label>Silence timeout (sec)</label><input type="number" id="silence_timeout" step="0.5" min="0.5" max="10"></div>
  <div class="row"><label>Max duration (sec)</label><input type="number" id="max_duration" step="1" min="5" max="120"></div>
  <div class="row"><label>Silence threshold</label><input type="number" id="silence_threshold" step="100" min="100" max="5000"></div>
</div>

<div class="section">
  <div class="section-title">Formatting</div>
  <div class="row"><label>Auto CJK-English spacing</label><label class="toggle"><input type="checkbox" id="auto_spacing"><span class="slider"></span></label></div>
  <div class="row"><label>Capitalize first letter</label><label class="toggle"><input type="checkbox" id="capitalize"><span class="slider"></span></label></div>
</div>

<div class="section">
  <div class="section-title">Hotwords</div>
  <div class="hotword-area"><input type="text" id="hw_input" placeholder="Add hotword..."><button class="btn btn-add" onclick="addHW()">Add</button></div>
  <div class="tags" id="hw_tags"></div>
</div>

<div class="save-bar">
  <span class="status" id="status">Saved!</span>
  <button class="btn btn-save" onclick="doSave()">Save</button>
</div>

<script>
let hotwords = __HOTWORDS__;
const config = __CONFIG__;

document.getElementById('silence_timeout').value = config.silence_timeout || 2;
document.getElementById('max_duration').value = config.max_duration || 30;
document.getElementById('silence_threshold').value = config.silence_threshold || 500;
document.getElementById('auto_spacing').checked = (config.formatting||{}).auto_spacing !== false;
document.getElementById('capitalize').checked = (config.formatting||{}).capitalize !== false;
renderTags();

function renderTags() {
  const el = document.getElementById('hw_tags');
  if (!hotwords.length) { el.innerHTML = '<span class="empty-hint">No hotwords</span>'; return; }
  el.innerHTML = hotwords.map((w,i) => '<span class="tag">'+w+'<span class="del" onclick="rmHW('+i+')">x</span></span>').join('');
}
function addHW() {
  const inp = document.getElementById('hw_input');
  const w = inp.value.trim();
  if (w && !hotwords.includes(w)) { hotwords.push(w); renderTags(); }
  inp.value = ''; inp.focus();
}
document.getElementById('hw_input').onkeydown = e => { if (e.key==='Enter') addHW(); };
function rmHW(i) { hotwords.splice(i,1); renderTags(); }
function doSave() {
  const data = {
    silence_timeout: parseFloat(document.getElementById('silence_timeout').value),
    max_duration: parseInt(document.getElementById('max_duration').value),
    silence_threshold: parseInt(document.getElementById('silence_threshold').value),
    formatting: { auto_spacing: document.getElementById('auto_spacing').checked, capitalize: document.getElementById('capitalize').checked, replacements: {} },
    hotwords: hotwords
  };
  // Send data to Python via custom URL scheme
  window.webkit.messageHandlers.saveSettings.postMessage(JSON.stringify(data));
  const s = document.getElementById('status'); s.classList.add('show');
  setTimeout(() => s.classList.remove('show'), 2000);
}
</script>
</body></html>"""


# Global reference to prevent garbage collection
_settings_window_ref = None


def _build_html(config, hotwords):
    """Build the settings HTML with injected data."""
    html = HTML_TEMPLATE.replace('__CONFIG__', json.dumps(config))
    html = html.replace('__HOTWORDS__', json.dumps(hotwords))
    return html


if HAS_WEBKIT:
    # Define the WKScriptMessageHandler delegate class
    # Use protocols= to declare WKScriptMessageHandler conformance (PyObjC 12.x)
    _WKScriptMessageHandler = objc.protocolNamed('WKScriptMessageHandler')

    class SettingsMessageHandler(AppKit.NSObject, protocols=[_WKScriptMessageHandler]):
        """Handles JavaScript -> Python messages from WKWebView."""

        @objc.python_method
        def initWithCallback_(self, callback):
            self = objc.super(SettingsMessageHandler, self).init()
            if self is None:
                return None
            self._callback = callback
            return self

        def userContentController_didReceiveScriptMessage_(self, controller, message):
            """Called when JS sends a message via webkit.messageHandlers."""
            try:
                body = message.body()
                data = json.loads(body)
                hotwords = data.pop('hotwords', [])

                # Save config file
                config_file = CONFIG_DIR / "settings.json"
                config_file.parent.mkdir(parents=True, exist_ok=True)
                with open(config_file, "w", encoding="utf-8") as f:
                    json.dump(data, f, ensure_ascii=False, indent=4)

                # Save hotwords file
                with open(CONFIG_DIR / "hotwords.txt", "w", encoding="utf-8") as f:
                    f.write("\n".join(hotwords) + "\n")

                # Call the on_save callback
                if self._callback:
                    self._callback(data, hotwords)

                logger.info("Settings saved successfully")
            except Exception as e:
                logger.error(f"Failed to save settings: {e}")


def open_settings(config, hotwords, on_save=None):
    """Open the settings window.

    Uses a native NSWindow + WKWebView when PyObjC WebKit is available,
    otherwise falls back to the HTTP server + browser approach.
    """
    if HAS_WEBKIT:
        _open_native_settings(config, hotwords, on_save)
    else:
        _open_browser_settings(config, hotwords, on_save)


def _open_native_settings(config, hotwords, on_save=None):
    """Open settings in a native NSWindow with WKWebView."""
    global _settings_window_ref

    def _create_window():
        global _settings_window_ref

        # If window already exists and is valid, bring it to front
        if _settings_window_ref is not None:
            try:
                win = _settings_window_ref['window']
                if win is not None:
                    # Reload HTML in case config changed
                    html = _build_html(config, hotwords)
                    _settings_window_ref['webview'].loadHTMLString_baseURL_(html, None)
                    win.makeKeyAndOrderFront_(None)
                    AppKit.NSApp.activateIgnoringOtherApps_(True)
                    return
            except Exception:
                pass
            _settings_window_ref = None

        # Create WKWebView configuration with message handler
        wk_config = WebKit.WKWebViewConfiguration.alloc().init()
        content_controller = WebKit.WKUserContentController.alloc().init()

        handler = SettingsMessageHandler.alloc().initWithCallback_(on_save)
        content_controller.addScriptMessageHandler_name_(handler, "saveSettings")
        wk_config.setUserContentController_(content_controller)

        # Create the window
        frame = Foundation.NSMakeRect(0, 0, 540, 680)
        style = (
            AppKit.NSWindowStyleMaskTitled
            | AppKit.NSWindowStyleMaskClosable
            | AppKit.NSWindowStyleMaskResizable
        )
        window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame,
            style,
            AppKit.NSBackingStoreBuffered,
            False,
        )
        window.setTitle_("VibeKeyboard Settings")
        window.center()
        window.setLevel_(AppKit.NSFloatingWindowLevel)

        # Create WKWebView
        webview = WebKit.WKWebView.alloc().initWithFrame_configuration_(
            frame, wk_config
        )
        webview.setAutoresizingMask_(
            AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable
        )

        # Set webview background to match HTML
        webview.setValue_forKey_(False, "drawsBackground")

        window.setContentView_(webview)

        # Build and load HTML
        html = _build_html(config, hotwords)
        webview.loadHTMLString_baseURL_(html, None)

        # Show window and bring to front
        window.makeKeyAndOrderFront_(None)
        AppKit.NSApp.activateIgnoringOtherApps_(True)

        # Store references to prevent garbage collection
        _settings_window_ref = {
            'window': window,
            'webview': webview,
            'handler': handler,
            'content_controller': content_controller,
        }

        logger.info("Settings window opened (native WKWebView)")

    # Must run on main thread for UI operations
    if threading.current_thread() is threading.main_thread():
        _create_window()
    else:
        AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(_create_window)


def _open_browser_settings(config, hotwords, on_save=None):
    """Fallback: open settings via HTTP server + system browser."""
    import http.server
    import webbrowser

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            html = _build_html(config, hotwords)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(html.encode())

        def do_POST(self):
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length))
            hw = body.pop('hotwords', [])

            config_file = CONFIG_DIR / "settings.json"
            config_file.parent.mkdir(parents=True, exist_ok=True)
            with open(config_file, "w", encoding="utf-8") as f:
                json.dump(body, f, ensure_ascii=False, indent=4)
            with open(CONFIG_DIR / "hotwords.txt", "w", encoding="utf-8") as f:
                f.write("\n".join(hw) + "\n")
            if on_save:
                on_save(body, hw)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

        def log_message(self, *args):
            pass

    def _serve():
        server = http.server.HTTPServer(('127.0.0.1', 0), _Handler)
        port = server.server_address[1]
        logger.info(f"Settings server on port {port}")
        webbrowser.open(f'http://127.0.0.1:{port}')
        server.handle_request()  # GET
        server.handle_request()  # POST (save)
        server.server_close()
        logger.info("Settings server closed")

    threading.Thread(target=_serve, daemon=True).start()
