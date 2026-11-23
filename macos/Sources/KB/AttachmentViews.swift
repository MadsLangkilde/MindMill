import AppKit
import ImageIO
import KBCore
import SwiftUI
import UniformTypeIdentifiers

extension AppModel {
    var appDataURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KB")
    }

    /// Adds files to the session's input box, skipping ones already there.
    func attach(_ urls: [URL], to s: WorkSession) {
        let new = urls.map { Attachment(url: $0) }.filter { a in !s.pendingAttachments.contains(a) }
        s.pendingAttachments += new
    }

    /// Saves image bytes from the clipboard or a drag (a picture copied in a browser) and adds it to the input box.
    func attachImage(_ data: Data, ext: String, sourceURL: URL?, to s: WorkSession) {
        do {
            let a = try AttachmentStore.saveImage(data, name: AttachmentStore.imageName(sourceURL: sourceURL, ext: ext),
                                                  base: appDataURL, session: s.id)
            s.pendingAttachments.append(a)
        } catch {
            errorMessage = "Could not keep the pasted image: \(error.localizedDescription)"
        }
    }

    /// Files or a copied image on the clipboard go into the input box. False when it holds text to paste as usual.
    func attachFromPasteboard(_ pb: NSPasteboard, to s: WorkSession) -> Bool {
        let files = ClipboardFiles.fileURLs(pb)
        let image = ClipboardFiles.imageData(pb)
        switch AttachmentPaste.kind(fileCount: files.count, hasImage: image != nil, string: pb.string(forType: .string)) {
        case .files: attach(files, to: s)
        case .image:
            guard let image else { return false }
            attachImage(image.data, ext: image.ext, sourceURL: ClipboardFiles.sourceURL(pb), to: s)
        case .text: return false
        }
        return true
    }

    /// Files and images dragged onto the input box.
    func attachDropped(_ providers: [NSItemProvider], to s: WorkSession) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { self.attach([url], to: s) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = ClipboardFiles.png(data) else { return }
                    DispatchQueue.main.async { self.attachImage(png, ext: "png", sourceURL: nil, to: s) }
                }
            }
        }
        return handled
    }

    func pickAttachments(for s: WorkSession) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Attach"
        panel.message = "Files, images or folders to send with your message"
        if panel.runModal() == .OK { attach(panel.urls, to: s) }
    }

    func removeAttachmentFolder(for s: WorkSession) {
        try? FileManager.default.removeItem(at: AttachmentStore.folder(base: appDataURL, session: s.id))
    }
}

/// Reading files and images off the clipboard.
enum ClipboardFiles {
    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// The image on the clipboard, as PNG or JPEG bytes.
    static func imageData(_ pb: NSPasteboard) -> (data: Data, ext: String)? {
        if let d = pb.data(forType: .png) { return (d, "png") }
        if let d = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) { return (d, "jpg") }
        for type in [NSPasteboard.PasteboardType.tiff, .init("public.heic"), .init("org.webmproject.webp"), .init("com.compuserve.gif")] {
            if let d = pb.data(forType: type), let png = png(d) { return (png, "png") }
        }
        return nil
    }

    /// Where a copied picture came from, when the browser says.
    static func sourceURL(_ pb: NSPasteboard) -> URL? {
        guard let url = NSURL(from: pb) as URL?, !url.isFileURL else { return nil }
        return url
    }

    static func png(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Small pictures of attached images, made once per file.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ path: String, side: Int = 480) -> NSImage? {
        let key = "\(side):\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// One attachment: a picture for an image, the file's icon and name otherwise.
struct AttachmentChip: View {
    let attachment: Attachment
    var height: CGFloat = 56
    var onRemove: (() -> Void)?

    var body: some View {
        Group {
            if attachment.isImage, let img = Thumbnails.image(attachment.path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: height * 3, maxHeight: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.path))
                        .resizable().frame(width: 20, height: 20)
                    Text(attachment.name).font(.callout).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .offset(x: 5, y: -5)
                .help("Remove")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(attachment.url) }
        .help(attachment.path)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(attachment.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) }
            if let onRemove { Button("Remove", action: onRemove) }
        }
    }
}

/// The attachments waiting in a session's input box.
struct PendingAttachments: View {
    let session: WorkSession

    var body: some View {
        if !session.pendingAttachments.isEmpty {
            ChipRow(spacing: 8, alignment: .top) {
                ForEach(session.pendingAttachments) { a in
                    AttachmentChip(attachment: a) { session.pendingAttachments.removeAll { $0 == a } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The files and images sent with a message, above it in the transcript.
struct MessageAttachments: View {
    let attachments: [Attachment]

    var body: some View {
        ChipRow(spacing: 8, alignment: .top) {
            ForEach(attachments) { a in AttachmentChip(attachment: a, height: 160) }
        }
        .frame(maxWidth: 520, alignment: .trailing)
    }
}

/// ⌘V in the focused input box with files or a picture on the clipboard: they become attachments instead of text.
struct AttachmentPasteHandler: ViewModifier {
    let active: Bool
    let paste: (NSPasteboard) -> Bool
    @State private var box = PasteBox()

    final class PasteBox {
        var active = false
        weak var window: NSWindow?
        var monitor: Any?
        var paste: ((NSPasteboard) -> Bool)?
    }

    func body(content: Content) -> some View {
        content
            .background(WindowFinder { box.window = $0 })
            .onAppear {
                box.active = active
                box.paste = paste
                guard box.monitor == nil else { return }
                let box = box
                box.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard box.active, event.window === box.window, event.window?.isKeyWindow == true,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers?.lowercased() == "v",
                          box.paste?(NSPasteboard.general) == true else { return event }
                    return nil
                }
            }
            .onChange(of: active) { _, now in box.active = now }
            .onDisappear {
                if let m = box.monitor { NSEvent.removeMonitor(m) }
                box.monitor = nil
            }
    }
}

private struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { found(view.window) }
    }
}

extension View {
    func pastesAttachments(active: Bool, _ paste: @escaping (NSPasteboard) -> Bool) -> some View {
        modifier(AttachmentPasteHandler(active: active, paste: paste))
    }
}
