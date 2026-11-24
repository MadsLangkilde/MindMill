import AppKit
import KBCore
import KBEngine
import SwiftUI

/// The focused text field's editor, for the caret and for typing into it at the caret.
@MainActor
enum FieldEditor {
    static var current: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }
}

extension AppModel {
    static let promptHistoryKey = "promptHistory"

    func recordPrompt(_ text: String) {
        promptHistory.record(text)
        UserDefaults.standard.set(promptHistory.entries, forKey: Self.promptHistoryKey)
    }
}

/// A prompt field that behaves like a terminal: ⇧↩ breaks the line, ↑ in an empty field or at the very start brings
/// back the prompts sent before, and ↓ walks forward again to what was being typed.
private struct PromptKeys: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    /// While a suggestion list uses the arrows.
    let paused: Bool
    @State private var recall = PromptRecall()

    func body(content: Content) -> some View {
        content
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                if let editor = FieldEditor.current {
                    editor.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    text += "\n"
                }
                return .handled
            }
            .onKeyPress(.upArrow) {
                let caret = FieldEditor.current?.selectedRange().location ?? (text.isEmpty ? 0 : (text as NSString).length)
                guard !paused, recall.takesUp(text: text, caret: caret, in: model.promptHistory) else { return .ignored }
                if let older = recall.older(current: text, in: model.promptHistory) { show(older) }
                return .handled
            }
            .onKeyPress(.downArrow) {
                let caret = FieldEditor.current.map { NSMaxRange($0.selectedRange()) } ?? (text as NSString).length
                guard !paused, recall.takesDown(text: text, caret: caret, in: model.promptHistory) else { return .ignored }
                if let newer = recall.newer(in: model.promptHistory) { show(newer) }
                return .handled
            }
            .onChange(of: text) { _, new in
                if new.isEmpty { recall.reset() }
            }
    }

    private func show(_ value: String) {
        text = value
        DispatchQueue.main.async {
            FieldEditor.current?.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        }
    }
}

extension View {
    func promptKeys(_ text: Binding<String>, paused: Bool = false) -> some View {
        modifier(PromptKeys(text: text, paused: paused))
    }
}
