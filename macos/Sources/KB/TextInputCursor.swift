import AppKit

/// Every editable text field and text view in the app shows the text cursor (I-beam) under the mouse and a blinking
/// caret when focused, whatever the SwiftUI views around or over it do with the cursor.
@MainActor
enum TextInputCursor {
    private static var monitor: Any?
    private static var overText = false
    private static weak var focused: NSTextView?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp, .keyDown, .scrollWheel]) { event in
            let kind = event.type
            let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber)
            let location = event.locationInWindow
            // After the event is handled, so nothing it triggers sets another cursor over ours.
            DispatchQueue.main.async {
                switch kind {
                case .mouseMoved, .scrollWheel: updateCursor(window: window, at: location)
                default: updateCaret(window: window ?? NSApp.keyWindow)
                }
            }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
                updateCaret(window: note.object as? NSWindow)
            }
        }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
    }

    private static func updateCursor(window: NSWindow?, at location: NSPoint) {
        guard let window, window.isKeyWindow || window.isMainWindow, NSEvent.pressedMouseButtons == 0 else { return }
        let inside = textInput(under: location, in: window)
        if inside {
            NSCursor.iBeam.set()
        } else if NSCursor.current == NSCursor.iBeam, overText || !textUnder(location, in: window) {
            // Leaving a field, or an I-beam left over from selectable text above a button: buttons and the rest
            // set no cursor of their own, so the I-beam would stay.
            NSCursor.arrow.set()
        }
        overText = inside
    }

    /// Whether any text view is under the mouse (selectable text included), as the views' classes say.
    private static func textUnder(_ location: NSPoint, in window: NSWindow) -> Bool {
        guard let frame = window.contentView?.superview, var view = frame.hitTest(location) else { return false }
        for _ in 0..<3 {
            // The class's own name, not its generic arguments (a hosting view's can name any view).
            let name = String(describing: type(of: view)).prefix { $0 != "<" }
            if view is NSText || view is NSTextField || name.contains("Text") { return true }
            guard let up = view.superview else { return false }
            view = up
        }
        return false
    }

    /// Whether the view the mouse is over, as AppKit hit-tests it, is a visible editable field or one inside it.
    private static func textInput(under location: NSPoint, in window: NSWindow) -> Bool {
        guard let frame = window.contentView?.superview, var view = frame.hitTest(location) else { return false }
        for _ in 0..<6 {
            if isTextInput(view) { return isVisible(view) }
            guard let up = view.superview else { return false }
            view = up
        }
        return false
    }

    private static func isVisible(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let cur = v {
            if cur.isHidden || cur.alphaValue < 0.01 || (cur.layer?.opacity ?? 1) < 0.01 { return false }
            v = cur.superview
        }
        return !view.visibleRect.isEmpty
    }

    private static func isTextInput(_ view: NSView) -> Bool {
        if let tf = view as? NSTextField { return tf.isEditable && tf.isEnabled }
        if let tv = view as? NSTextView { return tv.isEditable && !tv.isFieldEditor }
        return false
    }

    /// A newly focused field gets a visible caret whose blinking starts over.
    private static func updateCaret(window: NSWindow?) {
        guard let tv = window?.firstResponder as? NSTextView, tv.isEditable else {
            focused = nil
            return
        }
        if tv.insertionPointColor.alphaComponent < 0.2 {
            tv.insertionPointColor = .textInsertionPointColor
        }
        guard tv !== focused else { return }
        focused = tv
        tv.updateInsertionPointStateAndRestartTimer(true)
    }
}
