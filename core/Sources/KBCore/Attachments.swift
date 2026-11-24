import Foundation
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif

/// A file or image sent with a message: pasted, dropped or picked. Images Claude sees directly; other files it reads.
public struct Attachment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isImage: Bool
    public var isFolder: Bool

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]

    public init(url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        path = url.path
        name = url.lastPathComponent
        isFolder = exists && isDir.boolValue
        isImage = !isFolder && Self.imageExtensions.contains(url.pathExtension.lowercased())
    }

    enum CodingKeys: String, CodingKey { case path, name, isImage, isFolder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        isImage = try c.decodeIfPresent(Bool.self, forKey: .isImage) ?? false
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
    }
}

/// Where pasted images and dropped image data are kept: one folder per session under the app's data.
public enum AttachmentStore {
    public static func folder(base: URL, session: String) -> URL {
        base.appendingPathComponent("attachments").appendingPathComponent(session)
    }

    /// `name` in `folder`, numbered ("Pasted image 2.png") when one by that name is already there.
    public static func uniqueURL(in folder: URL, name: String) -> URL {
        let first = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2... {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return first
    }

    /// Saves image bytes (PNG, JPEG, TIFF…) as a file in the session's folder and returns it as an attachment.
    public static func saveImage(_ data: Data, name: String, base: URL, session: String) throws -> Attachment {
        let dir = folder(base: base, session: session)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = uniqueURL(in: dir, name: name)
        try data.write(to: url, options: .atomic)
        return Attachment(url: url)
    }

    /// A file name for a pasted image: the name in its web address when there is one, else "Pasted image".
    public static func imageName(sourceURL: URL?, ext: String) -> String {
        if let last = sourceURL?.deletingPathExtension().lastPathComponent, !last.isEmpty, last != "/",
           last.count <= 80, last.range(of: #"^[\w .()-]+$"#, options: .regularExpression) != nil {
            return "\(last).\(ext)"
        }
        return "Pasted image.\(ext)"
    }
}

/// An image as Claude's API takes it in a message: base64 bytes and their media type.
public struct ImageBlock: Equatable, Sendable {
    public var mediaType: String
    public var base64: String

    public init(mediaType: String, base64: String) {
        self.mediaType = mediaType
        self.base64 = base64
    }

    /// The longest side Claude uses without scaling down further.
    public static let maxSide = 1568
    /// Raw bytes kept under the API's 5 MB per image once base64 makes them a third bigger.
    public static let maxBytes = 3_600_000

    /// The image at `url` scaled to fit `maxSide` and encoded as PNG, or JPEG when PNG is too big. Nil when it
    /// can't be read as an image. Without ImageIO (Windows), a PNG, JPEG, GIF or WebP file is sent as it is when it
    /// fits `maxBytes`; scaling it down there is the engine host's job (`ImageScaling` in KBEngine).
    public static func make(from url: URL, maxSide: Int = maxSide, maxBytes: Int = maxBytes) -> ImageBlock? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var side = maxSide
        while side >= 256 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            if let png = encode(image, type: .png), png.count <= maxBytes {
                return ImageBlock(mediaType: "image/png", base64: png.base64EncodedString())
            }
            if let jpeg = encode(image, type: .jpeg, quality: 0.85), jpeg.count <= maxBytes {
                return ImageBlock(mediaType: "image/jpeg", base64: jpeg.base64EncodedString())
            }
            side = side * 3 / 4
        }
        return nil
        #else
        return unscaled(from: url, maxBytes: maxBytes)
        #endif
    }

    /// The file's bytes as they are, when its type is one Claude takes and it is small enough.
    static func unscaled(from url: URL, maxBytes: Int) -> ImageBlock? {
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        guard let type = types[url.pathExtension.lowercased()], let data = try? Data(contentsOf: url),
              !data.isEmpty, data.count <= maxBytes else { return nil }
        return ImageBlock(mediaType: type, base64: data.base64EncodedString())
    }

    #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
    static func encode(_ image: CGImage, type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
    #endif
}

/// The text that goes with attachments, so Claude knows where each one is.
public enum AttachmentPrompt {
    /// At most this many images go into one message as pictures; the rest are listed for Claude to open.
    public static let maxInlineImages = 20

    /// `inline` are the paths of the images sent as pictures in the same message.
    public static func text(_ message: String, attachments: [Attachment], inline: Set<String>) -> String {
        guard !attachments.isEmpty else { return message }
        let lines = attachments.map { a -> String in
            if inline.contains(a.path) { return "- \(a.path) (image, shown above)" }
            if a.isFolder { return "- \(a.path) (folder)" }
            return "- \(a.path)" + (a.isImage ? " (image; open it with Read to see it)" : "")
        }
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = attachments.count == 1 ? "I attached a file:" : "I attached \(attachments.count) files:"
        let ask = body.isEmpty ? "\n\nHave a look at \(attachments.count == 1 ? "it" : "them")." : "\n\n\(body)"
        return intro + "\n" + lines.joined(separator: "\n") + "\nRead the ones that aren't shown as pictures when you need them." + ask
    }
}

/// What ⌘V does in a session's input box.
public enum AttachmentPaste {
    public enum Kind: Equatable, Sendable { case files, image, text }

    /// Copied files attach; a copied picture attaches unless the clipboard also has real text (Word and Excel put a
    /// picture of the selection next to its text); a browser's picture with only its address still attaches.
    public static func kind(fileCount: Int, hasImage: Bool, string: String?) -> Kind {
        if fileCount > 0 { return .files }
        guard hasImage else { return .text }
        let s = (string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .image }
        let isAddress = !s.contains(where: \.isWhitespace) && (URL(string: s)?.scheme?.hasPrefix("http") ?? false)
        return isAddress ? .image : .text
    }
}
