import sys
import json
import asyncio
import threading
import logging
import time
from PyQt6.QtWidgets import QApplication, QWidget, QLabel, QVBoxLayout
from PyQt6.QtCore import Qt, pyqtSignal, QObject
from PyQt6.QtGui import QPixmap, QImage
import websockets

from Xlib import X, XK, display
from Xlib.ext import xtest

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("TabCircle")

# --- UI Signals ---
class Signals(QObject):
    update_mru = pyqtSignal(list)
    show_overlay = pyqtSignal()
    hide_overlay = pyqtSignal()

signals = Signals()

# --- PyQt6 UI Overlay ---
class Overlay(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        
        self.layout = QVBoxLayout()
        self.label = QLabel("TabCircle Switcher\nWaiting for Ctrl+Tab...", self)
        self.label.setStyleSheet("color: white; font-size: 24px; background-color: rgba(30, 30, 30, 220); padding: 20px; border-radius: 10px;")
        self.label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.layout.addWidget(self.label)
        self.setLayout(self.layout)
        
        self.resize(400, 200)
        self.center()
        
        signals.update_mru.connect(self.on_mru_update)
        signals.show_overlay.connect(self.do_show)
        signals.hide_overlay.connect(self.do_hide)

    def do_show(self):
        self.center()
        self.show()

    def do_hide(self):
        self.hide()

    def center(self):
        qr = self.frameGeometry()
        cp = self.screen().availableGeometry().center()
        qr.moveCenter(cp)
        self.move(qr.topLeft())

    def on_mru_update(self, tabs):
        self.label.setText(f"TabCircle Switcher\n{len(tabs)} Tabs Available\n(Release Ctrl to switch)")

# --- WebSocket & State ---
ws_clients = set()
latest_tabs = []
selected_tab_id = None

async def send_to_extension(msg_dict):
    if not ws_clients:
        return
    msg = json.dumps(msg_dict)
    for c in ws_clients:
        try:
            await c.send(msg)
        except Exception:
            pass

async def ws_handler(websocket):
    global latest_tabs
    logger.info("Extension connected.")
    ws_clients.add(websocket)
    
    await websocket.send(json.dumps({
        "type": "settings",
        "scopeToWindow": True,
        "tabLifetimeHours": 12
    }))
    await websocket.send(json.dumps({"type": "requestMRU"}))
    
    try:
        async for message in websocket:
            try:
                data = json.loads(message)
                msg_type = data.get("type", "unknown")
                if msg_type == "mru":
                    latest_tabs = data.get("tabs", [])
                    signals.update_mru.emit(latest_tabs)
                elif msg_type == "thumb":
                    pass # Ignore for now
            except json.JSONDecodeError:
                pass
    except Exception:
        pass
    finally:
        ws_clients.remove(websocket)

def start_ws_server():
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    server = websockets.serve(ws_handler, "127.0.0.1", 41573)
    loop.run_until_complete(server)
    loop.run_forever()

# --- Xlib Keyboard Interception ---
def is_chromium_active(d):
    try:
        root = d.screen().root
        NET_ACTIVE_WINDOW = d.intern_atom('_NET_ACTIVE_WINDOW')
        WM_CLASS = d.intern_atom('WM_CLASS')
        window_id = root.get_full_property(NET_ACTIVE_WINDOW, X.AnyPropertyType).value[0]
        window = d.create_resource_object('window', window_id)
        wm_class = window.get_full_property(WM_CLASS, X.AnyPropertyType).value
        class_str = wm_class.decode('utf-8', errors='ignore').lower()
        
        # Check against common chromium-based browser class names
        for browser in ['chromium', 'chrome', 'brave', 'edge', 'vivaldi']:
            if browser in class_str:
                return True
    except Exception:
        pass
    return False

def xlib_listener():
    d = display.Display()
    root = d.screen().root

    tab_keycode = d.keysym_to_keycode(XK.string_to_keysym("Tab"))
    ctrl_mask = X.ControlMask
    
    # Grab Ctrl+Tab with all combinations of NumLock (Mod2), CapsLock (Lock), ScrollLock (Mod5)
    modifiers = [
        0,
        X.Mod2Mask,
        X.LockMask,
        X.Mod5Mask,
        X.Mod2Mask | X.LockMask,
        X.Mod2Mask | X.Mod5Mask,
        X.LockMask | X.Mod5Mask,
        X.Mod2Mask | X.LockMask | X.Mod5Mask
    ]
    
    for mod in modifiers:
        root.grab_key(tab_keycode, ctrl_mask | mod, 1, X.GrabModeAsync, X.GrabModeAsync)
    
    logger.info("Xlib Listener started. Waiting for Ctrl+Tab...")
    
    while True:
        event = d.next_event()
        if event.type == X.KeyPress and event.detail == tab_keycode and (event.state & ctrl_mask):
            
            if is_chromium_active(d):
                logger.info("Ctrl+Tab intercepted in Chromium. Showing TabCircle UI.")
                signals.show_overlay.emit()
                
                # Grab entire keyboard to listen for release
                status = root.grab_keyboard(True, X.GrabModeAsync, X.GrabModeAsync, X.CurrentTime)
                if status != X.GrabSuccess:
                    logger.error("Failed to grab keyboard.")
                    signals.hide_overlay.emit()
                    continue
                
                # UI is open, wait for Ctrl release
                ctrl_released = False
                while not ctrl_released:
                    e = d.next_event()
                    if e.type == X.KeyRelease:
                        # Check if Ctrl was released
                        keysym = d.keycode_to_keysym(e.detail, 0)
                        if keysym in (XK.XK_Control_L, XK.XK_Control_R):
                            ctrl_released = True
                    elif e.type == X.KeyPress:
                        # User pressed something else while holding Ctrl (e.g., Tab again)
                        # We would handle cycling here in Phase 4
                        pass
                
                # Ctrl released
                root.ungrab_keyboard(X.CurrentTime)
                d.sync()
                signals.hide_overlay.emit()
                
                # Fire switch command to extension
                if len(latest_tabs) > 1:
                    # Switch to the previous tab (index 1 in MRU)
                    target_tab_id = latest_tabs[1].get('id')
                    logger.info(f"Switching to tab {target_tab_id}")
                    # Run asyncio coroutine from this thread
                    asyncio.run(send_to_extension({"type": "switch", "tabId": target_tab_id}))
                    
            else:
                # Not Chromium, replay the synthetic key
                for mod in modifiers:
                    root.ungrab_key(tab_keycode, ctrl_mask | mod)
                d.sync()
                
                # Send fake Ctrl+Tab
                xtest.fake_input(d, X.KeyPress, tab_keycode, current_window=X.NONE)
                xtest.fake_input(d, X.KeyRelease, tab_keycode, current_window=X.NONE)
                d.sync()
                
                # Re-grab
                for mod in modifiers:
                    root.grab_key(tab_keycode, ctrl_mask | mod, 1, X.GrabModeAsync, X.GrabModeAsync)
                d.sync()

if __name__ == "__main__":
    # 1. Start WS server
    threading.Thread(target=start_ws_server, daemon=True).start()
    
    # 2. Start Xlib listener
    threading.Thread(target=xlib_listener, daemon=True).start()
    
    # 3. Start PyQt App
    app = QApplication(sys.argv)
    overlay = Overlay()
    sys.exit(app.exec())
