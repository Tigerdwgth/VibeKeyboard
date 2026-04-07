import AppKit
import Foundation

// MARK: - Constants

private let kCornerRadius: CGFloat = 10
private let kWidthMin: CGFloat = 160
private let kWidthMax: CGFloat = 520
private let kHeightMin: CGFloat = 40
private let kHeightMax: CGFloat = 300
private let kInitialDotSize: CGFloat = 36
private let kIndicatorSize: CGFloat = 10
private let kIndicatorLeftPad: CGFloat = 14
private let kTextLeftPadWithIndicator: CGFloat = 32
private let kTextLeftPadNoIndicator: CGFloat = 12
private let kTextRightPad: CGFloat = 12

// MARK: - OverlayWindow

/// A borderless, floating, transparent overlay window with frosted glass background.
/// Displays recognized text near the mouse cursor with a colored status indicator dot.
///
/// - Red dot: recording
/// - Green dot: done
/// - Blue dot: processing
/// - Orange dot: error/empty
///
/// Uses NSVisualEffectView with `.hudWindow` material and a maskImage for rounded corners
/// (NOT layer.cornerRadius, which causes white edges on macOS).
final class OverlayWindow {

    private var window: NSWindow?
    private var backgroundView: NSVisualEffectView?
    private var textField: NSTextField?
    private var indicator: NSView?

    private var cachedMask: NSImage?
    private var cachedMaskSize: NSSize = .zero

    private let fontSize: CGFloat

    // MARK: - Init

    init(fontSize: CGFloat = 13) {
        self.fontSize = fontSize
        setup()
    }

    // MARK: - Setup

    private func setup() {
        let frame = NSRect(x: 100, y: 100, width: kInitialDotSize, height: kHeightMin)

        // Borderless, floating, transparent window
        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = .floating
        win.isOpaque = false
        win.backgroundColor = .clear
        win.ignoresMouseEvents = true
        win.isMovableByWindowBackground = false
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        win.alphaValue = 0.0
        win.hidesOnDeactivate = false
        self.window = win

        // Frosted glass background with maskImage for rounded corners
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.maskImage = getMask(width: frame.width, height: frame.height)
        win.contentView = bg
        self.backgroundView = bg

        // Status indicator dot — vertically centered
        let indicatorY = (frame.height - kIndicatorSize) / 2.0
        let indicatorView = NSView(frame: NSRect(
            x: kIndicatorLeftPad,
            y: indicatorY,
            width: kIndicatorSize,
            height: kIndicatorSize
        ))
        indicatorView.wantsLayer = true
        indicatorView.layer?.cornerRadius = kIndicatorSize / 2.0
        indicatorView.layer?.backgroundColor = NSColor.systemRed.cgColor
        bg.addSubview(indicatorView)
        self.indicator = indicatorView

        // Text field — word wrapping, unlimited lines
        let tf = NSTextField(frame: NSRect(
            x: kTextLeftPadWithIndicator,
            y: 0,
            width: frame.width - kTextLeftPadWithIndicator - kTextRightPad,
            height: frame.height
        ))
        tf.isEditable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isSelectable = false
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        tf.textColor = .black
        tf.lineBreakMode = .byWordWrapping
        tf.maximumNumberOfLines = 0
        tf.stringValue = ""
        tf.cell?.wraps = true
        tf.cell?.lineBreakMode = .byWordWrapping
        bg.addSubview(tf)
        self.textField = tf
    }

    // MARK: - Rounded Corner Mask

    /// Generate a rounded-rect mask image. Caches by size to avoid redundant allocations.
    private func getMask(width: CGFloat, height: CGFloat) -> NSImage {
        let w = ceil(width)
        let h = ceil(height)
        let size = NSSize(width: w, height: h)

        if let cached = cachedMask, cachedMaskSize == size {
            return cached
        }

        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                xRadius: kCornerRadius,
                                yRadius: kCornerRadius)
        NSColor.black.setFill()
        path.fill()
        image.unlockFocus()

        cachedMask = image
        cachedMaskSize = size
        return image
    }

    // MARK: - Layout

    /// Recalculate window size and subview frames based on current text content.
    private func relayout() {
        guard let win = window,
              let bg = backgroundView,
              let tf = textField,
              let ind = indicator else { return }

        let display = tf.stringValue
        guard !display.isEmpty else { return }

        let indicatorVisible = !ind.isHidden
        let leftPad = indicatorVisible ? kTextLeftPadWithIndicator : kTextLeftPadNoIndicator
        let rightPad = kTextRightPad

        // Compute single-line natural width
        let attrStr = tf.attributedStringValue
        let singleLineRect = attrStr.boundingRect(
            with: NSSize(width: 10000, height: 0),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let naturalWidth = singleLineRect.size.width

        // New window width: clamp between min and max
        let newWidth = max(kWidthMin, min(kWidthMax, naturalWidth + leftPad + rightPad))
        let availableWidth = newWidth - leftPad - rightPad

        // Compute multi-line height within constrained width
        let boundingRect = attrStr.boundingRect(
            with: NSSize(width: availableWidth, height: 0),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textHeight = boundingRect.size.height
        let newHeight = max(kHeightMin, min(kHeightMax, textHeight + 24))

        // Resize window — keep top edge stationary
        var frame = win.frame
        frame.origin.y -= (newHeight - frame.size.height)
        frame.size.width = newWidth
        frame.size.height = newHeight
        win.setFrame(frame, display: true, animate: false)

        // Sync background + mask
        bg.frame = NSRect(x: 0, y: 0, width: newWidth, height: newHeight)
        bg.maskImage = getMask(width: newWidth, height: newHeight)

        // Text field: vertically centered
        let textFieldHeight = min(textHeight + 4, newHeight - 4)
        let textY = (newHeight - textFieldHeight) / 2.0
        tf.frame = NSRect(x: leftPad, y: textY, width: availableWidth, height: textFieldHeight)

        // Horizontal alignment
        tf.alignment = indicatorVisible ? .left : .center

        // Indicator: vertically centered
        if indicatorVisible {
            let indicatorY = (newHeight - kIndicatorSize) / 2.0
            ind.setFrameOrigin(NSPoint(x: kIndicatorLeftPad, y: indicatorY))
        }
    }

    // MARK: - Public API (all main-thread safe)

    /// Show the overlay near the mouse cursor.
    /// - Parameters:
    ///   - text: Initial text to display (empty for recording start).
    ///   - showIndicator: Whether to show the colored status dot.
    func show(text: String = "", showIndicator: Bool = true) {
        ensureMainThread { [self] in
            guard let win = window,
                  let bg = backgroundView,
                  let tf = textField,
                  let ind = indicator else { return }

            tf.stringValue = text

            if showIndicator {
                ind.layer?.backgroundColor = NSColor.systemRed.cgColor
                ind.isHidden = false
            } else {
                ind.isHidden = true
            }

            if !text.isEmpty {
                relayout()
            } else {
                // Empty text: show a small dot
                let initW = kInitialDotSize
                var frame = win.frame
                frame.size.width = initW
                frame.size.height = kHeightMin
                win.setFrame(frame, display: true)

                bg.frame = NSRect(x: 0, y: 0, width: initW, height: kHeightMin)
                bg.maskImage = getMask(width: initW, height: kHeightMin)

                tf.frame = NSRect(x: kTextLeftPadWithIndicator, y: 0, width: 1, height: kHeightMin)

                let indicatorY = (kHeightMin - kIndicatorSize) / 2.0
                ind.setFrameOrigin(NSPoint(x: kIndicatorLeftPad, y: indicatorY))
            }

            // Position near mouse cursor
            let mouseLocation = NSEvent.mouseLocation
            let winWidth = win.frame.size.width
            let winHeight = win.frame.size.height
            var x = mouseLocation.x + 15
            var y = mouseLocation.y - winHeight - 10  // below cursor

            if let screen = NSScreen.main {
                let sf = screen.visibleFrame
                // Prevent overflow right
                if x + winWidth > sf.origin.x + sf.size.width {
                    x = mouseLocation.x - winWidth - 15
                }
                // Prevent overflow bottom
                if y < sf.origin.y {
                    y = mouseLocation.y + 20
                }
            }

            win.setFrameOrigin(NSPoint(x: x, y: y))
            win.orderFrontRegardless()

            // Fade in
            win.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                win.animator().alphaValue = 0.95
            }
        }
    }

    /// Update the displayed text and indicator color.
    /// Strips emoji prefixes and maps them to indicator colors.
    func updateText(_ text: String) {
        ensureMainThread { [self] in
            guard let tf = textField,
                  let ind = indicator else { return }

            // Strip emoji prefix for display
            var display = text
            let prefixes = ["\u{1F3A4} ", "\u{23F3} ", "\u{2705} ", "\u{274C} "]  // 🎤 ⏳ ✅ ❌
            for prefix in prefixes {
                if display.hasPrefix(prefix) {
                    display = String(display.dropFirst(prefix.count))
                    break
                }
            }
            tf.stringValue = display

            // Map emoji prefix to indicator color
            if text.hasPrefix("\u{2705}") {          // ✅ done → green
                ind.layer?.backgroundColor = NSColor.systemGreen.cgColor
            } else if text.hasPrefix("\u{274C}") || text.hasPrefix("(") || text.hasPrefix("\u{FF08}") {
                // ❌ error or （empty） → orange
                ind.layer?.backgroundColor = NSColor.systemOrange.cgColor
            } else if text.hasPrefix("\u{23F3}") {   // ⏳ processing → blue
                ind.layer?.backgroundColor = NSColor.systemBlue.cgColor
            } else {
                // Default: red (recording)
                ind.layer?.backgroundColor = NSColor.systemRed.cgColor
            }

            relayout()
        }
    }

    /// Hide the overlay with a fade-out animation.
    func hide() {
        ensureMainThread { [self] in
            guard let win = window else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                win.animator().alphaValue = 0.0
            } completionHandler: {
                if win.alphaValue < 0.1 {
                    win.orderOut(nil)
                }
            }
        }
    }

    /// Hide the overlay instantly without animation.
    /// Used before pasting to avoid the animation delay interfering with
    /// target app activation timing.
    func hideInstant() {
        ensureMainThread { [self] in
            guard let win = window else { return }
            win.alphaValue = 0.0
            win.orderOut(nil)
        }
    }

    // MARK: - Thread Safety

    private func ensureMainThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
