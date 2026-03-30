"""浮窗模块 — 显示实时识别中间结果

使用 PyObjC 原生 NSWindow，避免 PyQt6 与 rumps 双事件循环冲突。
浮窗运行在 rumps 的 NSApplication 主线程中。
"""

import logging
import threading

logger = logging.getLogger(__name__)

try:
    import AppKit
    import Foundation
    from Quartz import CGEventGetLocation, CGEventCreate

    HAS_APPKIT = True
except ImportError:
    HAS_APPKIT = False
    logger.warning("pyobjc-framework-Cocoa 未安装，浮窗不可用")


class OverlayWindow:
    """透明浮窗，显示 ASR 中间结果"""

    def __init__(self, font_size: int = 16):
        self.font_size = font_size
        self._window = None
        self._text_field = None
        self._text = ""

        if HAS_APPKIT:
            self._setup_window()

    def _setup_window(self):
        """创建原生浮窗"""
        # 初始窗口大小和位置（后续跟随鼠标）
        rect = Foundation.NSMakeRect(100, 100, 500, 60)

        style = AppKit.NSWindowStyleMaskBorderless
        self._window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect,
            style,
            AppKit.NSBackingStoreBuffered,
            False,
        )

        # 窗口属性：浮动、透明、不激活
        self._window.setLevel_(AppKit.NSFloatingWindowLevel)
        self._window.setOpaque_(False)
        self._window.setBackgroundColor_(AppKit.NSColor.clearColor())
        self._window.setIgnoresMouseEvents_(True)
        self._window.setHasShadow_(True)
        self._window.setCollectionBehavior_(
            AppKit.NSWindowCollectionBehaviorCanJoinAllSpaces
            | AppKit.NSWindowCollectionBehaviorStationary
        )

        # 圆角背景视图
        content_view = AppKit.NSVisualEffectView.alloc().initWithFrame_(rect)
        content_view.setMaterial_(AppKit.NSVisualEffectMaterialHUDWindow)
        content_view.setBlendingMode_(AppKit.NSVisualEffectBlendingModeBehindWindow)
        content_view.setState_(AppKit.NSVisualEffectStateActive)
        content_view.setWantsLayer_(True)
        content_view.layer().setCornerRadius_(10)
        content_view.layer().setMasksToBounds_(True)
        self._window.setContentView_(content_view)

        # 文字标签
        text_rect = Foundation.NSMakeRect(12, 8, 476, 44)
        self._text_field = AppKit.NSTextField.alloc().initWithFrame_(text_rect)
        self._text_field.setEditable_(False)
        self._text_field.setBezeled_(False)
        self._text_field.setDrawsBackground_(False)
        self._text_field.setSelectable_(False)
        self._text_field.setFont_(
            AppKit.NSFont.systemFontOfSize_weight_(self.font_size, AppKit.NSFontWeightMedium)
        )
        self._text_field.setTextColor_(AppKit.NSColor.labelColor())
        self._text_field.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
        self._text_field.setMaximumNumberOfLines_(3)

        content_view.addSubview_(self._text_field)

    def show(self, text: str = ""):
        """显示浮窗，定位在鼠标附近"""
        if not HAS_APPKIT or not self._window:
            return

        def _show():
            # 获取鼠标位置
            mouse_loc = AppKit.NSEvent.mouseLocation()
            screen = AppKit.NSScreen.mainScreen()
            if screen:
                screen_frame = screen.visibleFrame()
                # 浮窗在鼠标上方偏右
                x = min(mouse_loc.x + 20, screen_frame.origin.x + screen_frame.size.width - 520)
                y = min(mouse_loc.y + 30, screen_frame.origin.y + screen_frame.size.height - 80)
                self._window.setFrameOrigin_(Foundation.NSMakePoint(x, y))

            if text:
                self._text_field.setStringValue_(text)
            self._window.orderFrontRegardless()

        # 确保在主线程执行
        if threading.current_thread() is threading.main_thread():
            _show()
        else:
            AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(_show)

    def update_text(self, text: str):
        """更新浮窗文本（线程安全）"""
        self._text = text

        if not HAS_APPKIT or not self._window:
            return

        def _update():
            if self._text_field:
                self._text_field.setStringValue_(text)
                # 自适应高度
                self._text_field.sizeToFit()
                text_height = max(44, self._text_field.frame().size.height + 16)
                frame = self._window.frame()
                frame.size.height = text_height
                self._window.setFrame_display_(frame, True)

        if threading.current_thread() is threading.main_thread():
            _update()
        else:
            AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(_update)

    def hide(self):
        """隐藏浮窗"""
        if not HAS_APPKIT or not self._window:
            return

        def _hide():
            self._window.orderOut_(None)

        if threading.current_thread() is threading.main_thread():
            _hide()
        else:
            AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(_hide)
