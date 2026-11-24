import AppKit
import KBCore
import KBEngine
import SwiftUI

/// Files and web pages added for the meeting, each with what Claude found in it. Files can be dropped here too.
struct MeetingMaterialsView: View {
    @Environment(AppModel.self) private var model
    @Bindable var c: MeetingController
    @AppStorage("meetingMaterialsExpanded") private var expanded = true
    @State private var link = ""
    @State private var addingLink = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveCardLayout(spacing: 8, minInfoWidth: 180) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).font(.caption)
                            Text("Materials").font(.subheadline.weight(.semibold))
                            Text(c.materials.isEmpty ? "files and links for \(Brain.name)" : "\(c.materials.count)")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !c.readingMaterials.isEmpty { ProgressView().controlSize(.mini) }
                }
                HStack(spacing: 6) {
                    Button { addFiles() } label: { Label("Add Files…", systemImage: "doc.badge.plus").lineLimit(1).fixedSize() }
                        .help("Add documents, PDFs or pictures; \(Brain.name) reads them and keeps them in mind")
                    Button { addingLink.toggle() } label: { Label("Add Link…", systemImage: "link.badge.plus").lineLimit(1).fixedSize() }
                        .help("Add a web page; \(Brain.name) reads it and keeps it in mind")
                }
                .fixedSize()
            }
            .controlSize(.small)
            if expanded {
                if addingLink {
                    HStack(spacing: 6) {
                        TextField("https://…", text: $link).textFieldStyle(.roundedBorder).onSubmit(addLink)
                        Button("Add", action: addLink).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .controlSize(.small)
                }
                if c.materials.isEmpty {
                    Text("Drop files or links here, or use the buttons. \(Brain.name) reads each one and uses it during the meeting and in the summary.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(c.materials) { m in row(m) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(targeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { c.addMaterialFiles(files) }
            for url in urls where !url.isFileURL { c.addMaterialLink(url.absoluteString) }
            expanded = true
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func row(_ m: MeetingMaterial) -> some View {
        let reading = c.readingMaterials.contains(m.link)
        let unreadable = m.note.hasPrefix("Couldn't open it")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: m.isWeb ? "globe" : "doc.text").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Button { open(m) } label: {
                    Text(m.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .help(m.isWeb ? m.link : "Open the file")
                if reading {
                    Text("\(Brain.name) is reading it…").font(.caption).foregroundStyle(.secondary)
                } else if !m.note.isEmpty {
                    Text(m.note).font(.caption).foregroundStyle(unreadable ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if unreadable && m.isWeb, let url = URL(string: m.link) {
                    Button("Open in Mindmill's Browser and Share") { model.openCapture(url, for: .meeting(c.id)) }
                        .buttonStyle(.borderless).font(.caption)
                        .help("Sign in there if asked; the page's text goes to \(Brain.name)")
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Read It Again") { c.readMaterial(m) }
                Button("Remove", role: .destructive) { c.removeMaterial(m) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
    }

    private func open(_ m: MeetingMaterial) {
        if m.isWeb, let url = URL(string: m.link) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: c.location(of: m)))
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Files for the meeting. Mindmill keeps a copy with the meeting, and \(Brain.name) reads them."
        panel.prompt = "Add"
        if panel.runModal() == .OK { c.addMaterialFiles(panel.urls) }
    }

    private func addLink() {
        c.addMaterialLink(link)
        link = ""
        addingLink = false
    }
}
