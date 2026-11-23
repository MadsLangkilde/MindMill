import SwiftUI

/// Gives `content` a phase that swings between false and true for as long as `active` holds. The repeating
/// animation stays inside this view: a `withAnimation(.repeatForever)` started on appear also animated whatever
/// else changed in that update, such as Build laying out My Work, which then swung back and forth for ever.
struct Pulsing<Content: View>: View {
    var active = true
    var duration = 0.8
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        if active {
            PhaseAnimator([false, true], content: content) { _ in .easeInOut(duration: duration) }
        } else {
            content(false)
        }
    }
}
