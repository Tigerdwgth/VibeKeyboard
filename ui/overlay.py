"""浮窗模块 — 屏幕顶部居中的现代半透明浮窗"""

import logging
import threading

logger = logging.getLogger(__name__)

try:
    import AppKit
    import Foundation
    HAS_APPKIT = True
except ImportError:
    HAS_APPKIT = False


def _on_main(fn):
    if threading.current_thread() is threading.main_thread():
        fn()
    else:
        AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(fn)


# 常量
_W_DEFAULT = 420
_W_MAX = 520
_H_MIN = 40
_H_MAX = 160
_CORNER_RADIUS = 10


class OverlayWindow:
    def __init__(self, font_size: int = 15):
        self.font_size = font_size
        self._window = None
        self._text_field = None
        self._indicator = None
        self._bg = None
        self._last_mask_size = (0, 0)

        if HAS_APPKIT:
            self._setup()

    def _setup(self):
        W, H = _W_DEFAULT, _H_MIN

        rect = Foundation.NSMakeRect(100, 100, W, H)

        self._window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, AppKit.NSWindowStyleMaskBorderless, AppKit.NSBackingStoreBuffered, False,
        )
        self._window.setLevel_(AppKit.NSFloatingWindowLevel)
        self._window.setOpaque_(False)
        self._window.setBackgroundColor_(AppKit.NSColor.clearColor())
        self._window.setIgnoresMouseEvents_(False)
        self._window.setMovableByWindowBackground_(True)
        self._window.setHasShadow_(True)
        self._window.setCollectionBehavior_(
            AppKit.NSWindowCollectionBehaviorCanJoinAllSpaces
            | AppKit.NSWindowCollectionBehaviorStationary
        )
        self._window.setAlphaValue_(0.0)

        # 毛玻璃背景 — 用 maskImage 实现圆角，避免 layer cornerRadius 的白边问题
        bg = AppKit.NSVisualEffectView.alloc().initWithFrame_(
            Foundation.NSMakeRect(0, 0, W, H)
        )
        bg.setMaterial_(AppKit.NSVisualEffectMaterialHUDWindow)
        bg.setBlendingMode_(AppKit.NSVisualEffectBlendingModeBehindWindow)
        bg.setState_(AppKit.NSVisualEffectStateActive)
        bg.setMaskImage_(self._get_mask(W, H, _CORNER_RADIUS))
        self._window.setContentView_(bg)
        self._bg = bg

        # 录音指示灯（小圆点）— 垂直居中
        indicator_y = (H - 10) / 2.0
        self._indicator = AppKit.NSView.alloc().initWithFrame_(
            Foundation.NSMakeRect(14, indicator_y, 10, 10)
        )
        self._indicator.setWantsLayer_(True)
        self._indicator.layer().setCornerRadius_(5)
        self._indicator.layer().setBackgroundColor_(
            AppKit.NSColor.systemRedColor().CGColor()
        )
        bg.addSubview_(self._indicator)

        # 文字 — 支持最多 3 行自动换行
        self._text_field = AppKit.NSTextField.alloc().initWithFrame_(
            Foundation.NSMakeRect(32, 0, W - 44, H)
        )
        self._text_field.setEditable_(False)
        self._text_field.setBezeled_(False)
        self._text_field.setDrawsBackground_(False)
        self._text_field.setSelectable_(False)
        self._text_field.setFont_(
            AppKit.NSFont.systemFontOfSize_weight_(self.font_size, AppKit.NSFontWeightRegular)
        )
        self._text_field.setTextColor_(AppKit.NSColor.blackColor())
        self._text_field.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
        self._text_field.setMaximumNumberOfLines_(3)
        self._text_field.setStringValue_("")
        # 让 cell 也支持换行
        self._text_field.cell().setWraps_(True)
        self._text_field.cell().setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
        bg.addSubview_(self._text_field)

    def _get_mask(self, w, h):
        """获取圆角 mask，尺寸不变时复用缓存"""
        w, h = int(w), int(h)
        if (w, h) != self._last_mask_size:
            image = AppKit.NSImage.alloc().initWithSize_(Foundation.NSMakeSize(w, h))
            image.lockFocus()
            path = AppKit.NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                Foundation.NSMakeRect(0, 0, w, h), _CORNER_RADIUS, _CORNER_RADIUS
            )
            AppKit.NSColor.blackColor().setFill()
            path.fill()
            image.unlockFocus()
            self._cached_mask = image
            self._last_mask_size = (w, h)
        return self._cached_mask

    def _relayout(self):
        """根据当前文字内容重新计算窗口和子视图尺寸，文字垂直居中"""
        display = self._text_field.stringValue()
        if not display:
            return

        # 用 attributedString 计算单行自然宽度
        attr_str = self._text_field.attributedStringValue()
        single_line = attr_str.boundingRectWithSize_options_(
            Foundation.NSMakeSize(10000, 0),
            AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading,
        )
        natural_w = single_line.size.width
        new_w = max(160, min(_W_MAX, natural_w + 52))
        available_w = new_w - 44

        # 在限定宽度下计算多行高度
        bounding = attr_str.boundingRectWithSize_options_(
            Foundation.NSMakeSize(available_w, 0),
            AppKit.NSStringDrawingUsesLineFragmentOrigin | AppKit.NSStringDrawingUsesFontLeading,
        )
        text_h = bounding.size.height
        new_h = max(_H_MIN, min(_H_MAX, text_h + 24))

        # 调整窗口大小（保持顶部位置不动）
        frame = self._window.frame()
        frame.origin.y -= (new_h - frame.size.height)
        frame.size.width = new_w
        frame.size.height = new_h
        self._window.setFrame_display_animate_(frame, True, False)

        # 同步背景 + mask
        self._bg.setFrame_(Foundation.NSMakeRect(0, 0, new_w, new_h))
        self._bg.setMaskImage_(self._get_mask(new_w, new_h, _CORNER_RADIUS))

        # 文字垂直居中
        text_field_h = min(text_h + 4, new_h - 4)
        text_y = (new_h - text_field_h) / 2.0
        self._text_field.setFrame_(Foundation.NSMakeRect(32, text_y, available_w, text_field_h))

        # 指示灯垂直居中
        indicator_y = (new_h - 10) / 2.0
        self._indicator.setFrameOrigin_(Foundation.NSMakePoint(14, indicator_y))

    def show(self, text: str = ""):
        if not HAS_APPKIT or not self._window:
            return

        def _show():
            self._text_field.setStringValue_(text)
            self._indicator.layer().setBackgroundColor_(
                AppKit.NSColor.systemRedColor().CGColor()
            )
            self._indicator.setHidden_(False)

            # 初始小尺寸
            init_w = 36
            frame = self._window.frame()
            frame.size.width = init_w
            frame.size.height = _H_MIN
            self._window.setFrame_display_(frame, True)
            self._bg.setFrame_(Foundation.NSMakeRect(0, 0, init_w, _H_MIN))
            self._bg.setMaskImage_(self._get_mask(init_w, _H_MIN, _CORNER_RADIUS))
            self._text_field.setFrame_(Foundation.NSMakeRect(32, 0, 1, _H_MIN))
            indicator_y = (_H_MIN - 10) / 2.0
            self._indicator.setFrameOrigin_(Foundation.NSMakePoint(14, indicator_y))

            # 跟随鼠标光标位置
            mouse = AppKit.NSEvent.mouseLocation()
            screen = AppKit.NSScreen.mainScreen()
            W = self._window.frame().size.width
            H = self._window.frame().size.height
            x = mouse.x + 15
            y = mouse.y - H - 10  # 光标下方

            if screen:
                sf = screen.visibleFrame()
                # 防止超出屏幕右边
                if x + W > sf.origin.x + sf.size.width:
                    x = mouse.x - W - 15
                # 防止超出屏幕下边
                if y < sf.origin.y:
                    y = mouse.y + 20

            self._window.setFrameOrigin_(Foundation.NSMakePoint(x, y))
            self._window.orderFrontRegardless()

            self._window.setAlphaValue_(0.0)
            AppKit.NSAnimationContext.beginGrouping()
            AppKit.NSAnimationContext.currentContext().setDuration_(0.15)
            self._window.animator().setAlphaValue_(0.95)
            AppKit.NSAnimationContext.endGrouping()

        _on_main(_show)

    def update_text(self, text: str):
        if not HAS_APPKIT or not self._window:
            return

        def _update():
            # 去掉 emoji 前缀，只显示纯文本
            display = text
            for prefix in ("🎤 ", "⏳ ", "✅ ", "❌ "):
                if display.startswith(prefix):
                    display = display[len(prefix):]
                    break

            self._text_field.setStringValue_(display)

            # 根据状态切换指示灯颜色
            if text.startswith("✅"):
                self._indicator.layer().setBackgroundColor_(
                    AppKit.NSColor.systemGreenColor().CGColor()
                )
            elif text.startswith("❌") or text.startswith("（"):
                self._indicator.layer().setBackgroundColor_(
                    AppKit.NSColor.systemOrangeColor().CGColor()
                )
            elif text.startswith("⏳"):
                self._indicator.layer().setBackgroundColor_(
                    AppKit.NSColor.systemBlueColor().CGColor()
                )
            else:
                self._indicator.layer().setBackgroundColor_(
                    AppKit.NSColor.systemRedColor().CGColor()
                )

            self._relayout()

        _on_main(_update)

    def hide(self):
        if not HAS_APPKIT or not self._window:
            return

        def _hide():
            AppKit.NSAnimationContext.beginGrouping()
            AppKit.NSAnimationContext.currentContext().setDuration_(0.2)
            self._window.animator().setAlphaValue_(0.0)
            AppKit.NSAnimationContext.endGrouping()
            # 动画结束后隐藏
            def _order_out():
                if self._window.alphaValue() < 0.1:
                    self._window.orderOut_(None)
            threading.Timer(0.25, lambda: _on_main(_order_out)).start()

        _on_main(_hide)
