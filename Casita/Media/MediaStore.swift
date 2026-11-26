import AVFoundation
import Foundation
import ImageIO
import PDFKit
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a file in a space is, told from its name alone.
enum MediaKind: Sendable {
    case image, video, pdf, text, other

    init(name: String) {
        switch UTType(filenameExtension: (name as NSString).pathExtension) {
        case let t? where t.conforms(to: .image): self = .image
        case let t? where t.conforms(to: .movie): self = .video
        case let t? where t.conforms(to: .pdf): self = .pdf
        case let t? where t.conforms(to: .text): self = .text
        default: self = .other
        }
    }

    /// Photos and videos belong to the gallery; everything else to Files.
    var isGalleryItem: Bool { self == .image || self == .video }
}

/// One file in a space. Its thumbnail, if any, is the file `<name>.thumb`.
struct MediaItem: Identifiable, Hashable, Sendable {
    static let thumbSuffix = ".thumb"
    let name: String
    var id: String { name }
    var kind: MediaKind { MediaKind(name: name) }
    var thumbName: String { name + Self.thumbSuffix }
    var utType: UTType { UTType(filenameExtension: (name as NSString).pathExtension) ?? .data }
}

extension ReservedStorage {
    /// Files in a space, newest first. Thumbnails and Casita's own files are
    /// left out: those are named with a folder ("web/session.json", the
    /// space's web logins; "app/place.json"), which a person's files never
    /// are, so they never show in Files to be shared or deleted.
    func mediaItems(in space: SpaceRef) throws -> [MediaItem] {
        try fileNames(in: space)
            .filter { !$0.hasSuffix(MediaItem.thumbSuffix) && !$0.contains("/") }
            .reversed().map(MediaItem.init)
    }

    func deleteItem(_ item: MediaItem, in space: SpaceRef) throws {
        try deleteFile(named: item.name, in: space)
        try? deleteFile(named: item.thumbName, in: space)
    }
}

// MARK: Import

enum MediaImport {
    /// Puts a temporary file into the space and deletes it. The file is
    /// memory-mapped, so even a long video never sits in RAM as a whole.
    // `writeFile` takes one Data; map the file instead of streaming
    // chunk by chunk. Add a chunk-stream API to Storage if videos ever exceed
    // what mapping handles comfortably.
    @discardableResult
    static func importFile(at url: URL, named preferred: String? = nil, into storage: ReservedStorage, space: SpaceRef) async throws -> MediaItem {
        defer { MediaTemp.remove(url) }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try await importData(data, named: preferred ?? url.lastPathComponent, videoURL: url, into: storage, space: space)
    }

    /// Writes `data` as a new file plus its thumbnail. `videoURL` is only
    /// needed for videos, which AVFoundation reads from a file.
    @discardableResult
    static func importData(_ data: Data, named preferred: String, videoURL: URL? = nil, into storage: ReservedStorage, space: SpaceRef) async throws -> MediaItem {
        let item = MediaItem(name: try await storage.addUserFile(named: preferred, data: data, in: space))
        if let thumb = await Thumbnail.make(data: data, kind: item.kind, videoURL: videoURL) {
            try await storage.writeFile(named: item.thumbName, data: thumb, in: space)
        }
        return item
    }

    /// "a.jpg" becomes "a 2.jpg" when "a.jpg" is already there, so nothing is
    /// silently replaced.
    static func uniqueName(_ name: String, in storage: ReservedStorage, space: SpaceRef) async throws -> String {
        try await storage.availableUserFileName(name, in: space)
    }
}

/// What `PhotosPicker` hands over: a copy on disk under `MediaTemp`, so a
/// large video is never loaded into memory by the picker.
struct PickedFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(url: try MediaTemp.copyIn($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try MediaTemp.copyIn($0.file)) }
    }
}

// MARK: Thumbnails

enum Thumbnail {
    static let maxPixels = 400

    /// A small JPEG made in memory; nil for kinds that have no picture.
    static func make(data: Data, kind: MediaKind, videoURL: URL? = nil) async -> Data? {
        let image: CGImage?
        switch kind {
        case .image:
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary
            image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
        case .video:
            guard let videoURL else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            image = try? await generator.image(at: .zero).image
        case .pdf:
            let size = CGSize(width: maxPixels, height: maxPixels)
            image = PDFDocument(data: data)?.page(at: 0)?.thumbnail(of: size, for: .cropBox).cgImage
        case .text, .other:
            return nil
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    /// A picture decoded in memory for the screen, upright, no larger than
    /// `maxPixels` on its long side. Runs off the main thread.
    static func display(data: Data, maxPixels: Int) async -> UIImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

extension Thumbnail {
    /// Makes and stores the thumbnail of a photo or video that has none:
    /// the share extension saves files without them.
    // Reads the whole file to make it; stream from storage if large videos make this slow.
    static func makeMissing(for item: MediaItem, storage: ReservedStorage, space: SpaceRef) async -> Data? {
        guard item.kind.isGalleryItem, let data = try? await storage.readFile(named: item.name, in: space) else { return nil }
        let videoURL = item.kind == .video ? try? MediaTemp.write(data, named: item.name) : nil
        defer { videoURL.map(MediaTemp.remove) }
        guard let thumb = await make(data: data, kind: item.kind, videoURL: videoURL) else { return nil }
        try? await storage.writeFile(named: item.thumbName, data: thumb, in: space)
        return thumb
    }
}

// MARK: Temporary unlocked copies

/// The only place an unlocked copy ever touches disk: QuickLook and the share
/// sheet need a file. Each copy has complete file protection, lives in its own
/// folder, is removed when its view goes away, and the whole folder is swept
/// at every lock and at launch, in case a view or the app died first.
enum MediaTemp {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("casita-media", isDirectory: true)

    static func write(_ data: Data, named name: String) throws -> URL {
        let url = try freshFolder().appendingPathComponent(name)
        try data.write(to: url, options: .completeFileProtection)
        return url
    }

    /// Copies a file the system handed over (picker, file importer) into a
    /// protected temporary folder of our own.
    static func copyIn(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let url = try freshFolder().appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        return url
    }

    /// A path for a new file in a fresh protected folder.
    static func newFile(named name: String) throws -> URL {
        try freshFolder().appendingPathComponent(name)
    }

    /// Removes a temporary file together with its folder.
    static func remove(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let inside = folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
        try? FileManager.default.removeItem(at: inside ? folder : url)
    }

    /// At launch everything goes. On lock (`keepingBackups`) a backup being
    /// written or exported stays, and so does a folder still empty, which may
    /// be one about to get its backup.
    static func sweep(keepingBackups: Bool = false) {
        guard keepingBackups else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        for folder in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            let isBackup = names.contains { ($0 as NSString).pathExtension == BackupFile.fileExtension }
            if !names.isEmpty, !isBackup { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// Every file currently in the temporary folder. Tests use it to prove
    /// nothing is left behind.
    static func files() -> [URL] {
        guard let all = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return all.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func freshFolder() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return folder
    }
}

// MARK: Delete originals

enum DeleteOriginals {
    enum Outcome: Sendable { case deleted, denied, cancelled }

    /// Asks for Photos access only now, then deletes the picked originals.
    static func run(identifiers: [String]) async -> Outcome {
        guard Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil else { return .denied }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return .denied }
        // Limited access rarely covers what the picker handed over, and
        // deleting nothing succeeds: never say "deleted" then.
        guard PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).count == Set(identifiers).count else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
            }
            return .deleted
        } catch {
            return .cancelled
        }
    }

    static let recentlyDeletedReminder = "Also empty Recently Deleted in Photos. Deleted photos stay there for up to 30 days, and no app can empty it for you."
    static let manualSteps = "Casita can't delete them without Photos access. In Photos, select the originals and delete them, then empty Recently Deleted. To let Casita do it next time, allow Photos under Settings > Apps > Casita."
}

/// Plain words for errors a space can show without revealing anything about
/// other spaces.
func mediaErrorText(_ error: any Error) -> String {
    switch error as? StorageError {
    case .noRoom: "No room left in this space"
    case .noSuchFile: "That file is gone"
    default: error.localizedDescription
    }
}
