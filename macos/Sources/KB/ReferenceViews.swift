import AppKit
import KBCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct NewMailReferenceRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
    let kind: ReferenceKind
}

extension AppModel {
    /// Writes a reference entry and opens it. Returns its id.
    @discardableResult
    func saveReference(project: String, title: String, kind: ReferenceKind, url: URL?, note: String, content: String,
                       fields: [String: String] = [:]) -> EntryID? {
        do {
            var doc = try KBStore.newDocument(project: project, section: .references, title: title, root: rootURL)
            doc.frontmatter.setString("kind", kind.rawValue)
            if let url { doc.frontmatter.setString("url", url.absoluteString) }
            doc.frontmatter.setString("captured", KBDate.today())
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) { doc.frontmatter.setString(k, v) }
            doc.body = ReferenceBody.make(note: note, content: content)
            try KBStore.save(&doc, root: rootURL)
            reload()
            notice = "Saved “\(title)” to References."
            return doc.id
        } catch {
            errorMessage = "Could not save the reference: \(error.localizedDescription)"
            return nil
        }
    }

    /// Replaces a reference's copy, keeping its note.
    func refreshReference(_ id: EntryID, content: String) {
        do {
            var doc = try KBStore.load(id, root: rootURL)
            doc.body = ReferenceBody.replacingContent(doc.body, with: content)
            doc.frontmatter.setString("captured", KBDate.today())
            try KBStore.save(&doc, root: rootURL)
            reload()
            if document?.id == id { openNow(id) }
            notice = "Updated the saved copy of “\(doc.title)”."
        } catch {
            errorMessage = "Could not update the reference: \(error.localizedDescription)"
        }
    }

    func referenceFromMail(project: String, kind: ReferenceKind, lookFor: String, note: String) {
        let q = lookFor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = kind == .teams ? "teams" : "email"
        newSession(title: "Save \(kind.title.lowercased())", project: project,
                   message: "/kb:reference \(action) \(project) \(q)" + (n.isEmpty ? "" : "\n\nWhy it matters: \(n)"),
                   display: "Save \(kind == .teams ? "a Teams chat" : "an email") to References: \(q)")
    }

    func chooseReferenceFiles(project: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, .rtf, .html, UTType(filenameExtension: "md") ?? .plainText,
                                     UTType(filenameExtension: "docx") ?? .data]
        panel.message = "Pick files to keep a copy of their text in References."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importReferenceFile(url, project: project) }
    }

    func importReferenceFile(_ url: URL, project: String) {
        guard let text = Self.text(of: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Couldn't read any text from \(url.lastPathComponent)."
            return
        }
        let kind: ReferenceKind = ["pdf", "docx", "pptx", "rtf"].contains(url.pathExtension.lowercased()) ? .document : .file
        let id = saveReference(project: project, title: url.deletingPathExtension().lastPathComponent, kind: kind, url: nil,
                               note: "", content: text, fields: ["file": url.path])
        if let id { selectEntry(id) }
    }

    static func text(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: url)?.string
        case "docx", "rtf", "html", "htm", "doc":
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// A dropped link opens in the browser to be saved; a dropped file is saved straight away.
    func dropIntoReferences(_ urls: [URL], project: String) -> Bool {
        for url in urls {
            if url.isFileURL {
                importReferenceFile(url, project: project)
            } else if url.scheme?.hasPrefix("http") == true {
                openCapture(url, for: .newReference(project))
            }
        }
        return !urls.isEmpty
    }
}

// MARK: List

/// Saved copies of artifacts, emails, chats, pages and documents in a scope, to read again and for Claude to use.
struct ReferencesView: View {
    @Environment(AppModel.self) private var model
    let project: KBProject
    @State private var askingLink = false
    @State private var link = ""
    @State private var dropping = false

    var body: some View {
        let every = model.index.entries(project: project.id, section: .references).filter { !$0.isDraft }
        let query = model.listQuery(.references)
        let all = query.isEmpty ? every : every.filter { $0.matches(query) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(every.count) saved").font(.headline)
                Spacer()
                addMenu
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if !every.isEmpty { ListSearchField(key: .references, prompt: "Search references") }
            Divider()
            if all.isEmpty && !every.isEmpty {
                ListEmptyState(title: "No references match “\(query)”", systemImage: "magnifyingglass")
            } else if all.isEmpty {
                ListEmptyState(title: "No References", systemImage: "bookmark", message: "Keep a copy of a \(Brain.name) artifact, an email, a Teams chat, a web page or a file. Ask, briefs and sessions can then find and read it. Drop a link or a file here, or use Add.") {
                    addMenu
                }
            } else {
                List(selection: model.entrySelection) {
                    DraftsSection(drafts: model.index.entries(project: project.id, section: .references).filter(\.isDraft))
                    ForEach(ReferenceKind.allCases, id: \.self) { kind in
                        let rows = all.filter { $0.referenceKind == kind }
                        if !rows.isEmpty {
                            Section("\(kind.title)s · \(rows.count)") {
                                ForEach(rows) { ReferenceRow(entry: $0).tag($0.id).entryContextMenu($0.id) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.dropIntoReferences(urls, project: project.id)
        } isTargeted: { dropping = $0 }
        .navigationSubtitle("References")
        .alert("Save a Web Page or \(Brain.name) Artifact", isPresented: $askingLink) {
            TextField("https://…", text: $link)
            Button("Open") {
                if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true {
                    model.openCapture(url, for: .newReference(project.id))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It opens in Mindmill's browser, where you can sign in. Then press Save to References.")
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Web Page or \(Brain.name) Artifact…") {
                link = NSPasteboard.general.string(forType: .string).flatMap { $0.hasPrefix("http") ? $0 : nil } ?? ""
                askingLink = true
            }
            Button("Email…") { model.newMailReferenceRequest = NewMailReferenceRequest(project: project.id, kind: .email) }
            Button("Teams Chat…") { model.newMailReferenceRequest = NewMailReferenceRequest(project: project.id, kind: .teams) }
            Button("File…") { model.chooseReferenceFiles(project: project.id) }
            Button("Note…") { model.requestNewEntry(.references) }
            Divider()
            Menu("Sign In Once") {
                Button("\(Brain.name) (for artifacts)") { model.openCapture(URL(string: "https://claude.ai/login")!, for: .clipboard) }
                Button("Microsoft 365 (SharePoint, Outlook on the web)") { model.openCapture(URL(string: "https://www.office.com")!, for: .clipboard) }
            }
            Button("Sources Ask Searches…") {
                model.projectSettingsRequest = ProjectSettingsRequest(project: project.id, tab: .sources)
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .fixedSize()
        .help("Save a copy of something to read again later")
    }
}

struct ReferenceRow: View {
    let entry: KBEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.referenceKind.icon).foregroundStyle(Color.accentColor).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.headline).lineLimit(2)
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let host = entry.referenceURL?.host { Text(host).lineLimit(1) }
                    if let c = entry.field("captured") { Text("saved \(DateText.short(c))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Detail

struct ReferenceBanner: View {
    @Environment(AppModel.self) private var model
    let entry: KBEntry

    var body: some View {
        let kind = entry.referenceKind
        HStack(spacing: 10) {
            ChipRow(spacing: 8) {
                Label(kind.title, systemImage: kind.icon).fontWeight(.semibold)
                if let c = entry.field("captured") { Text("copy from \(DateText.display(c))").foregroundStyle(.secondary) }
                if let url = entry.referenceURL {
                    Link(destination: url) { Label("Open Original", systemImage: "arrow.up.right.square") }
                } else if let path = entry.field("file") {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label("Open File", systemImage: "doc") }
                        .buttonStyle(.link)
                }
            }
            Spacer(minLength: 8)
            if let url = entry.referenceURL, [.artifact, .web, .document].contains(kind) {
                Button("Update Copy") { model.openCapture(url, for: .reference(entry.id)) }
                    .help("Opens the page again in Mindmill's browser; Update Saved Copy replaces the text, keeping your note")
            }
            Button {
                model.askAbout(.entry(entry.id, title: entry.title))
            } label: {
                Label("Ask About It", systemImage: "questionmark.bubble")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: Sheets

struct NewMailReferenceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: NewMailReferenceRequest
    @State private var lookFor = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.kind == .teams ? "Save a Teams Chat" : "Save an Email").font(.title2.weight(.semibold))
            Text("\(Brain.name) finds it, asks which one if several fit, and saves a copy without email addresses.")
                .foregroundStyle(.secondary)
            TextField("Subject, a sender's name, or words from it", text: $lookFor)
                .textFieldStyle(.roundedBorder)
            TextField("Why it matters (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...)
                .scrollingInput(note, maxLines: 5)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Find and Save") {
                    model.referenceFromMail(project: request.project, kind: request.kind, lookFor: lookFor, note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(lookFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

/// In the browser window: name the copy, pick its scope, say why it matters.
struct SaveReferenceForm: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let pageTitle: String
    let text: String
    let project: String?
    let onSaved: () -> Void
    @State private var title = ""
    @State private var scope = ""
    @State private var note = ""
    @State private var kind: ReferenceKind = .web

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save to References").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Picker("Scope", selection: $scope) {
                ForEach(model.index.projects) { Text($0.title).tag($0.id) }
            }
            Picker("Kind", selection: $kind) {
                ForEach(ReferenceKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField("Why it matters (optional)", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...)
                .scrollingInput(note, maxLines: 5)
            Text("\(text.split(whereSeparator: \.isWhitespace).count) words are saved in the knowledge base on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Save") {
                    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.saveReference(project: scope, title: t.isEmpty ? (url.host ?? "Page") : t, kind: kind, url: url,
                                           note: note, content: text) != nil {
                        onSaved()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(scope.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            title = pageTitle
            scope = project ?? model.projectID ?? model.index.projects.first?.id ?? ""
            kind = ReferenceKind.guess(url)
        }
    }
}
