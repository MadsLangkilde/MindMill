import Foundation
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
import Testing
@testable import KBCore

@Suite struct AttachmentTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("kb-att-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func png(width: Int, height: Int) -> Data {
        #if canImport(ImageIO)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ImageBlock.encode(ctx.makeImage()!, type: .png)!
        #else
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #endif
    }

    @Test func pastingPrefersFilesThenPicturesButKeepsRealText() {
        #expect(AttachmentPaste.kind(fileCount: 2, hasImage: false, string: "a.txt\nb.txt") == .files)
        #expect(AttachmentPaste.kind(fileCount: 0, hasImage: true, string: nil) == .image)
        #expect(AttachmentPaste.kind(fileCount: 0, hasImage: true, string: "https://example.com/cat.png") == .image)
        // Word and Excel put a picture of the selection next to its text.
        #expect(AttachmentPaste.kind(fileCount: 0, hasImage: true, string: "Q3 numbers") == .text)
        #expect(AttachmentPaste.kind(fileCount: 0, hasImage: false, string: "hello") == .text)
    }

    @Test func pastedImagesGetUniqueNamesInTheSessionFolder() throws {
        let base = tempDir()
        let a = try AttachmentStore.saveImage(png(width: 4, height: 4), name: "Pasted image.png", base: base, session: "s1")
        let b = try AttachmentStore.saveImage(png(width: 4, height: 4), name: "Pasted image.png", base: base, session: "s1")
        #expect(a.name == "Pasted image.png" && a.isImage)
        #expect(b.name == "Pasted image 2.png")
        #expect(a.path.contains("/attachments/s1/"))
        #expect(AttachmentStore.imageName(sourceURL: URL(string: "https://x.com/img/cat%20photo.jpg"), ext: "png") == "cat photo.png")
        #expect(AttachmentStore.imageName(sourceURL: URL(string: "https://x.com/i?id=1&s=2"), ext: "png") == "i.png")
        #expect(AttachmentStore.imageName(sourceURL: nil, ext: "png") == "Pasted image.png")
    }

    #if canImport(ImageIO)
    @Test func bigImagesAreScaledForClaude() throws {
        let url = tempDir().appendingPathComponent("big.png")
        try png(width: 3000, height: 1500).write(to: url)
        let block = try #require(ImageBlock.make(from: url))
        #expect(block.mediaType == "image/png")
        let data = try #require(Data(base64Encoded: block.base64))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1568)
        #expect(ImageBlock.make(from: url.deletingLastPathComponent().appendingPathComponent("missing.png")) == nil)
    }
    #endif

    @Test func withoutImageIOImagesGoUnscaledWhenSmallEnough() throws {
        let dir = tempDir()
        let small = dir.appendingPathComponent("a.PNG")
        try Data([1, 2, 3]).write(to: small)
        #expect(ImageBlock.unscaled(from: small, maxBytes: 10) == ImageBlock(mediaType: "image/png", base64: Data([1, 2, 3]).base64EncodedString()))
        #expect(ImageBlock.unscaled(from: small, maxBytes: 2) == nil)
        let other = dir.appendingPathComponent("a.tiff")
        try Data([1]).write(to: other)
        #expect(ImageBlock.unscaled(from: other, maxBytes: 10) == nil)
    }

    @Test func messageCarriesImagesBeforeItsText() throws {
        let line = ClaudeStreamLine.userMessage("Look", images: [ImageBlock(mediaType: "image/png", base64: "AAA")])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let content = try #require((obj["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: Any])?["media_type"] as? String == "image/png")
    }

    @Test func promptListsWhereEachFileIs() {
        let img = Attachment(url: URL(fileURLWithPath: "/tmp/a.png"))
        let doc = Attachment(url: URL(fileURLWithPath: "/tmp/spec.pdf"))
        let text = AttachmentPrompt.text("Fix this", attachments: [img, doc], inline: [img.path])
        #expect(text.hasPrefix("I attached 2 files:"))
        #expect(text.contains("- /tmp/a.png (image, shown above)"))
        #expect(text.contains("- /tmp/spec.pdf\n"))
        #expect(text.hasSuffix("Fix this"))
        #expect(AttachmentPrompt.text("", attachments: [doc], inline: []).hasSuffix("Have a look at it."))
        #expect(AttachmentPrompt.text("Hi", attachments: [], inline: []) == "Hi")
    }

    @Test func recordsWithoutAttachmentsStillDecode() throws {
        let old = #"{"role":"user","text":"hi"}"#
        let m = try JSONDecoder().decode(SessionRecord.Message.self, from: Data(old.utf8))
        #expect(m.attachments == nil)
    }
}

@Suite struct PRBuildStateTests {
    private let approved = [PullRequest.Reviewer(name: "A", vote: 10)]

    @Test func expiredBuildIsItsOwnProblemAndNotBuilding() {
        let pr = PullRequest(id: 1, title: "x", reviewers: approved, blockers: [PRBlocker.buildExpired])
        #expect(PRProblem.of(pr) == .buildExpired)
        #expect(!PRProblem.buildExpired.needsFixing)
        #expect(!pr.waitingForChecks)
        #expect(PRRescue.blocked([pr]).isEmpty)
    }

    @Test func aQueuedBuildIsSaidOnce() {
        let queued = SessionStatus.PRState(canComplete: false, openThreads: 0, draft: false, approved: true,
                                           building: true, buildQueued: true)
        #expect(SessionStatus.stage(of: queued) == .buildQueued)
        #expect(PRProblem.shown(.buildQueued, status: .buildQueued) == nil)
        #expect(PRProblem.shown(.buildQueued, status: .building) == nil)
        #expect(PRProblem.shown(.buildQueued, status: .inReview) == .buildQueued)
        let running = PullRequest(id: 2, title: "y", reviewers: approved, blockers: [PRBlocker.buildRunning])
        #expect(!running.buildQueuedOnly)
        let waiting = PullRequest(id: 3, title: "z", reviewers: approved, blockers: [PRBlocker.buildQueued])
        #expect(waiting.buildQueuedOnly)
    }
}
