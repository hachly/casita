import AVFoundation
import CoreImage
import CoreML
import ImageIO
import Vision

/// Works out a photo's or video's facts on this iPhone: the date and place
/// written in the file, Vision's labels, and a print of each face. Nothing
/// is sent anywhere; Vision runs on the device.
enum PhotoScanner {
    /// Pictures are looked at no larger than this on their long side: big
    /// enough for faces across a room, small enough to stay quick.
    static let lookSize = 1600
    /// Faces narrower than this (in the looked-at picture) are too small to
    /// tell apart.
    static let smallestFace: CGFloat = 50
    /// Faces turned further than this from the camera are left out of
    /// people: a profile's print looks more like other profiles than like
    /// the same face from the front.
    static let mostTurned = 0.5 // radians, about 30°

    /// Nil when the file can't be read (the space locked, or it was deleted),
    /// so it is tried again later rather than marked as having no facts.
    static func facts(of item: MediaItem, storage: ReservedStorage, space: SpaceRef) async -> PhotoFacts.Photo? {
        var facts = PhotoFacts.Photo()
        guard let data = try? await storage.readFile(named: item.name, in: space) else { return nil }
        var picture: CGImage?
        switch item.kind {
        case .image:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return facts }
            read(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:], into: &facts)
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: lookSize,
            ] as CFDictionary
            picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        case .video:
            // AVFoundation reads from a file, so the video is copied
            // out whole, as the viewer does; stream from Storage if long videos matter.
            guard let url = try? MediaTemp.write(data, named: item.name) else { return facts }
            let asset = AVURLAsset(url: url)
            await readVideo(asset, into: &facts)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: lookSize, height: lookSize)
            picture = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            if picture == nil { picture = try? await generator.image(at: .zero).image }
            MediaTemp.remove(url)
        default:
            return facts
        }
        if let picture { await look(at: picture, into: &facts) }
        return facts
    }

    // MARK: What the file says

    static func read(_ properties: [CFString: Any], into facts: inout PhotoFacts.Photo) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let stamp = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        facts.taken = stamp.flatMap { exifDate($0, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String) }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
            place(south ? -lat : lat, west ? -lon : lon, into: &facts)
        }
        // iPhone screenshots say so in their EXIF comment.
        if (exif[kCGImagePropertyExifUserComment] as? String) == "Screenshot" { facts.labels.append("screenshot") }
    }

    /// "2024:07:14 18:30:05", in the time zone `offset` names ("+02:00"), or
    /// the iPhone's own when the camera didn't say.
    static func exifDate(_ stamp: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset, let zone = zone(offset) { formatter.timeZone = zone }
        return formatter.date(from: String(stamp.prefix(19)))
    }

    private static func zone(_ offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60))
    }

    static func readVideo(_ asset: AVURLAsset, into facts: inout PhotoFacts.Photo) async {
        let metadata = (try? await asset.load(.metadata)) ?? []
        func first(_ ids: [AVMetadataIdentifier]) -> AVMetadataItem? {
            ids.lazy.compactMap { AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: $0).first }.first
        }
        // The camera's own stamp; the movie header's date is often when it was exported.
        if let item = first([.quickTimeMetadataCreationDate, .commonIdentifierCreationDate]) {
            facts.taken = try? await item.load(.dateValue)
        }
        if facts.taken == nil, let item = try? await asset.load(.creationDate) { facts.taken = try? await item.load(.dateValue) }
        if let item = first([.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709, .commonIdentifierLocation]),
           let text = try? await item.load(.stringValue), let (lat, lon) = iso6709(text) {
            place(lat, lon, into: &facts)
        }
    }

    /// "+37.7858-122.4064+010.000/" to latitude and longitude.
    static func iso6709(_ text: String) -> (Double, Double)? {
        let numbers = text.matches(of: #/[+-]\d+(?:\.\d+)?/#).compactMap { Double($0.output) }
        guard numbers.count >= 2 else { return nil }
        return (numbers[0], numbers[1])
    }

    private static func place(_ lat: Double, _ lon: Double, into facts: inout PhotoFacts.Photo) {
        // 0,0 is what a broken GPS writes, not a photo taken off Africa.
        guard abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0 else { return }
        facts.latitude = lat
        facts.longitude = lon
        facts.place = CityIndex.shared.nearest(latitude: lat, longitude: lon)
    }

    // MARK: What is in the picture

    static func look(at picture: CGImage, into facts: inout PhotoFacts.Photo) async {
        if let labels = try? await runnable(ClassifyImageRequest()).perform(on: picture) {
            facts.labels += labels
                .filter { Thing.keeps(confidence: $0.confidence, highPrecision: $0.hasMinimumRecall(0.01, forPrecision: 0.9)) }
                .map(\.identifier)
        }
        // Pinned revisions: prints from different revisions can't be compared.
        guard let faces = try? await runnable(DetectFaceRectanglesRequest(.revision3)).perform(on: picture) else { return }
        let size = CGSize(width: picture.width, height: picture.height)
        let image = CIImage(cgImage: picture)
        for face in faces {
            let rect = face.boundingBox.toImageCoordinates(size, origin: .lowerLeft)
            guard rect.width >= smallestFace, abs(face.yaw.converted(to: .radians).value) <= mostTurned else { continue }
            let crop = upright(image, around: rect, roll: face.roll.converted(to: .radians).value)
            guard let print = try? await runnable(GenerateImageFeaturePrintRequest(.revision2)).perform(on: crop),
                  print.elementType == .float else { continue }
            let vector = print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let box = face.boundingBox
            facts.faces.append(PhotoFacts.Face(
                box: [Float(box.origin.x), Float(1 - box.origin.y - box.height), Float(box.width), Float(box.height)],
                print: PhotoFacts.packed(vector)
            ))
        }
    }

    /// The request as it can run here: the simulator has no GPU or Neural
    /// Engine for Vision's models ("Could not create inference context"), so
    /// there it runs on the CPU. An iPhone picks for itself.
    static func runnable<R: ImageProcessingRequest>(_ request: R) -> R {
        #if targetEnvironment(simulator)
        var request = request
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) {
            for stage in request.supportedComputeStageDevices.keys { request.setComputeDevice(cpu, for: stage) }
        }
        return request
        #else
        return request
        #endif
    }

    /// The face with some room around it (1.4 times its box, measured best),
    /// turned so the eyes are level.
    static func upright(_ image: CIImage, around rect: CGRect, roll: Double) -> CIImage {
        let side = max(rect.width, rect.height) * 1.4
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let square = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let turn = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: -roll))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return image.transformed(by: turn).cropped(to: square)
    }
}
