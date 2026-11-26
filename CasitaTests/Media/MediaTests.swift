import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UIKit
@testable import Casita

private let testBytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)

private func makeSpace() async throws -> (ReservedStorage, SpaceRef) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("casita-media-\(UUID().uuidString).bin")
    let storage = try ReservedStorage.create(at: url, bytes: testBytes, stretcher: PBKDF2Stretcher(iterations: 1000))
    return (storage, try await storage.createTopSpace(code: "1234"))
}

private func removeFile(_ storage: ReservedStorage) {
    try? FileManager.default.removeItem(at: storage.url)
}

/// A temporary file outside MediaTemp, like the ones the picker hands over.
private func tempFile(named name: String, _ data: Data) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func pngBytes(width: Int, height: Int) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).pngData { context in
        UIColor.orange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

private func pdfBytes() -> Data {
    UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 300)).pdfData { context in
        context.beginPage()
        "hello".draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
    }
}

private func decodedSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return CGSize(width: image.width, height: image.height)
}

// Serialized: the temp-folder tests share one directory.
@Suite(.serialized) struct MediaTests {
    @Test func imageRoundTripWithThumbnail() async throws {
        let (storage, space) = try await makeSpace()
        defer { removeFile(storage) }
        let png = pngBytes(width: 1200, height: 800)
        let input = try tempFile(named: "photo.png", png)

        let item = try await MediaImport.importFile(at: input, into: storage, space: space)
        #expect(item.name == "photo.png")
        #expect(item.kind == .image)
        #expect(try await storage.readFile(named: "photo.png", in: space) == png)
        #expect(!FileManager.default.fileExists(atPath: input.path), "temporary copy must be deleted")

        let thumb = try await storage.readFile(named: item.thumbName, in: space)
        let size = try #require(decodedSize(thumb))
        #expect(size.width == CGFloat(Thumbnail.maxPixels))
        #expect(size.height < size.width)
        #expect(try await storage.mediaItems(in: space) == [item], "thumbnails are not listed")
    }

    @Test func multiChunkVideoBlobRoundTrip() async throws {
        let (storage, space) = try await makeSpace()
        defer { removeFile(storage) }
        let blob = ReservedStorage.randomBytes(ReservedStorage.chunkPlain * 2 + 777)
        let input = try tempFile(named: "clip.mp4", blob)

        let item = try await MediaImport.importFile(at: input, into: storage, space: space)
        #expect(item.kind == .video)
        #expect(try await storage.readFile(named: "clip.mp4", in: space) == blob)
        #expect(!FileManager.default.fileExists(atPath: input.path))
    }

    @Test func pdfRoundTripWithThumbnail() async throws {
        let (storage, space) = try await makeSpace()
        defer { removeFile(storage) }
        let pdf = pdfBytes()
        let item = try await MediaImport.importFile(at: try tempFile(named: "paper.pdf", pdf), into: storage, space: space)
        #expect(item.kind == .pdf)
        let back = try await storage.readFile(named: "paper.pdf", in: space)
        #expect(back == pdf)
        #expect(PDFDocument(data: back)?.pageCount == 1)
        #expect(decodedSize(try await storage.readFile(named: item.thumbName, in: space)) != nil)
    }

    @Test func textRoundTripHasNoThumbnail() async throws {
        let (storage, space) = try await makeSpace()
        defer { removeFile(storage) }
        let text = Data("hello, space".utf8)
        let item = try await MediaImport.importFile(at: try tempFile(named: "note.txt", text), into: storage, space: space)
        #expect(item.kind == .text)
        #expect(try await storage.readFile(named: "note.txt", in: space) == text)
        #expect(try await storage.fileNames(in: space) == ["note.txt"])
    }

    @Test func sameNameTwiceKeepsBoth() async throws {
        let (storage, space) = try await makeSpace()
        defer { removeFile(storage) }
        let a = try await MediaImport.importFile(at: try tempFile(named: "a.txt", Data("1".utf8)), into: storage, space: space)
        let b = try await MediaImport.importFile(at: try tempFile(named: "a.txt", Data("2".utf8)), into: storage, space: space)
        #expect(a.name == "a.txt")
        #expect(b.name == "a 2.txt")
        #expect(try await storage.readFile(named: "a.txt", in: space) == Data("1".utf8))
    }

    @Test func deleteItemRemovesThumbnailToo() async throws {
        let (storage, space) = try await makeSpace()
        defer { removeFile(storage) }
        let item = try await MediaImport.importFile(at: try tempFile(named: "p.png", pngBytes(width: 50, height: 50)), into: storage, space: space)
        try await storage.deleteItem(item, in: space)
        #expect(try await storage.fileNames(in: space).isEmpty)
    }

    @Test func thumbnailIsCappedJPEG() async throws {
        let thumb = try #require(await Thumbnail.make(data: pngBytes(width: 300, height: 900), kind: .image))
        #expect(thumb.prefix(2) == Data([0xFF, 0xD8]), "JPEG magic")
        #expect(decodedSize(thumb) == CGSize(width: Thumbnail.maxPixels / 3, height: Thumbnail.maxPixels))
        #expect(await Thumbnail.make(data: Data("x".utf8), kind: .text) == nil)
    }

    /// The Office path: a protected temporary copy for QuickLook, gone once
    /// the viewer closes, and swept at launch if the app died first.
    @Test func officeTempCopyLeavesNothingBehind() throws {
        MediaTemp.sweep()
        let docx = ReservedStorage.randomBytes(5000)
        let url = try MediaTemp.write(docx, named: "report.docx")
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path), "stays inside the app container")
        #expect(MediaTemp.files() == [url])
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        #expect(protection == nil || protection == .complete)

        MediaTemp.remove(url)
        #expect(MediaTemp.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))

        _ = try MediaTemp.write(docx, named: "stray.docx")
        MediaTemp.sweep()
        #expect(MediaTemp.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: MediaTemp.directory.path))
    }

    /// The sweep at every lock: unlocked copies go, a backup being written stays.
    @Test func lockSweepKeepsOnlyBackups() throws {
        MediaTemp.sweep()
        let stray = try MediaTemp.write(Data("x".utf8), named: "clip.mov")
        let backup = try MediaTemp.write(Data("x".utf8), named: "Casita.\(BackupFile.fileExtension)")
        let pending = try MediaTemp.newFile(named: "Casita.\(BackupFile.fileExtension)")
        MediaTemp.sweep(keepingBackups: true)
        #expect(MediaTemp.files() == [backup])
        #expect(!FileManager.default.fileExists(atPath: stray.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: pending.deletingLastPathComponent().path))
        MediaTemp.sweep()
    }

    @Test func copyInLeavesTheOriginalAlone() throws {
        let pdf = pdfBytes()
        let original = try tempFile(named: "keep.pdf", pdf)
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let copy = try MediaTemp.copyIn(original)
        defer { MediaTemp.remove(copy) }
        #expect(copy.lastPathComponent == "keep.pdf")
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: copy) == pdf)
    }

    @Test func kindsFromNames() {
        #expect(MediaKind(name: "a.heic") == .image)
        #expect(MediaKind(name: "a.MOV") == .video)
        #expect(MediaKind(name: "a.pdf") == .pdf)
        #expect(MediaKind(name: "a.md") == .text)
        #expect(MediaKind(name: "a.docx") == .other)
        #expect(MediaKind(name: "noext") == .other)
    }
}
