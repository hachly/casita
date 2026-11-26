import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Casita

private final class Fixtures {
    static func image(_ name: String) throws -> CGImage {
        let url = try #require(Bundle(for: Fixtures.self).url(forResource: name, withExtension: "jpg"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}

/// A unit vector pointing mostly along `axis`, nudged by `jitter`.
private func print(_ axis: Int, _ jitter: Float = 0) -> Data {
    var v = [Float](repeating: 0, count: 8)
    v[axis] = 1
    v[(axis + 1) % 8] = jitter
    let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return PhotoFacts.packed(v.map { $0 / n })
}

private func face(_ axis: Int, _ jitter: Float = 0, width: Float = 0.2) -> PhotoFacts.Face {
    PhotoFacts.Face(box: [0.1, 0.1, width, width], print: print(axis, jitter))
}

@Suite struct PeopleTests {
    @Test func closeFacesBecomeOnePersonAndFarOnesDont() {
        var facts = PhotoFacts()
        facts.photos["a.jpg"] = .init(faces: [face(0)])
        facts.photos["b.jpg"] = .init(faces: [face(0, 0.1)])
        facts.photos["c.jpg"] = .init(faces: [face(3)])
        facts.groupFaces(in: ["a.jpg", "b.jpg", "c.jpg"])
        #expect(facts.people.count == 1)
        let shown = facts.peopleWithPhotos()
        #expect(shown.count == 1)
        #expect(Set(shown[0].photos) == ["a.jpg", "b.jpg"])
        #expect(facts.photos["c.jpg"]!.faces[0].person == nil)
    }

    @Test func aPhotoNeverHoldsOnePersonTwice() {
        var facts = PhotoFacts()
        // Twins in one photo: alike, but two people.
        facts.photos["twins.jpg"] = .init(faces: [face(0), face(0, 0.05)])
        facts.groupFaces(in: ["twins.jpg"])
        #expect(facts.people.isEmpty)
        facts.photos["later.jpg"] = .init(faces: [face(0, 0.02)])
        facts.groupFaces(in: ["later.jpg"])
        let people = facts.photos["twins.jpg"]!.faces.map(\.person)
        #expect(people.compactMap { $0 }.count == 1, "Only one twin joins the later face")
    }

    @Test func namesMergeAndNotThisPersonSticks() throws {
        var facts = PhotoFacts()
        facts.photos["a.jpg"] = .init(faces: [face(0)])
        facts.photos["b.jpg"] = .init(faces: [face(0, 0.1)])
        facts.photos["c.jpg"] = .init(faces: [face(5)])
        facts.photos["d.jpg"] = .init(faces: [face(5, 0.1)])
        facts.groupFaces(in: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        #expect(facts.people.count == 2)
        let anna = try #require(facts.photos["a.jpg"]!.faces[0].person)
        let other = try #require(facts.photos["c.jpg"]!.faces[0].person)
        facts.name(anna, "  Anna ")
        #expect(facts.person(anna)?.name == "Anna")

        // Same person: everything of the other joins Anna, who keeps her name.
        facts.merge(other, into: anna)
        #expect(facts.people.map(\.id) == [anna])
        #expect(Set(facts.peopleWithPhotos()[0].photos) == ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])

        // Not Anna: the photo leaves and a new look-alike doesn't bring it back.
        facts.remove("d.jpg", from: anna)
        #expect(facts.photos["d.jpg"]!.faces[0].person == nil)
        #expect(facts.photos["d.jpg"]!.faces[0].notPeople == [anna])
        facts.groupFaces(in: ["d.jpg"])
        #expect(facts.photos["d.jpg"]!.faces[0].person != anna)
    }

    @Test func aPersonDownToOnePhotoHidesUnlessNamed() throws {
        var facts = PhotoFacts()
        facts.photos["a.jpg"] = .init(faces: [face(0)])
        facts.photos["b.jpg"] = .init(faces: [face(0, 0.1)])
        facts.groupFaces(in: ["a.jpg", "b.jpg"])
        let id = try #require(facts.people.first?.id)
        facts.remove("b.jpg", from: id)
        #expect(facts.peopleWithPhotos().isEmpty)
        facts.name(id, "Leo")
        #expect(facts.peopleWithPhotos().map(\.person.name) == ["Leo"])
        // Deleting the last photo forgets the person.
        facts.prune(keeping: ["b.jpg"])
        #expect(facts.people.isEmpty)
    }

    @Test func theCoverIsTheBiggestFaceInAPhoto() throws {
        var facts = PhotoFacts()
        facts.photos["small.jpg"] = .init(faces: [face(0, width: 0.1)])
        facts.photos["big.jpg"] = .init(faces: [face(0, 0.1, width: 0.4)])
        facts.photos["bigger.mov"] = .init(faces: [face(0, 0.05, width: 0.6)])
        facts.groupFaces(in: ["small.jpg", "big.jpg", "bigger.mov"])
        let id = try #require(facts.people.first?.id)
        #expect(facts.cover(of: id)?.photo == "big.jpg")
    }

    @Test func photosWaitToBeGroupedUntilASortGetsToThem() {
        var facts = PhotoFacts()
        facts.photos["a.jpg"] = .init(faces: [face(0)])
        facts.photos["b.jpg"] = .init(faces: [face(0, 0.1)])
        facts.photos["c.jpg"] = .init()
        // A sort cancelled before grouping leaves them for the next one.
        #expect(facts.ungrouped == ["a.jpg", "b.jpg", "c.jpg"])
        facts.groupFaces(in: facts.ungrouped)
        #expect(facts.ungrouped.isEmpty)
        #expect(facts.people.count == 1)
    }

    @Test func printsSurviveFloat16() {
        let v: [Float] = [0.5, -0.25, 0.125, 0.75]
        #expect(PhotoFacts.vector(PhotoFacts.packed(v)) == v)
        #expect(abs(PhotoFacts.distance([0, 0], [3, 4]) - 5) < 0.0001)
    }
}

@Suite struct ThingsAndTimeTests {
    @Test func thingsGatherFromLabels() {
        var facts = PhotoFacts()
        facts.photos["soup.jpg"] = .init(labels: ["food", "bowl"])
        facts.photos["dog.jpg"] = .init(labels: ["animal", "dog", "canine"])
        facts.photos["tree.jpg"] = .init(labels: ["plant"])
        let things = Dictionary(uniqueKeysWithValues: facts.things().map { ($0.thing, Set($0.photos)) })
        #expect(things[.food] == ["soup.jpg"])
        #expect(things[.dogs] == ["dog.jpg"])
        #expect(things[.animals] == ["dog.jpg"])
        #expect(things[.flowers] == nil)
        #expect(Thing.keeps(confidence: 0.49, highPrecision: true))
        #expect(!Thing.keeps(confidence: 0.17, highPrecision: true))
        #expect(!Thing.keeps(confidence: 0.9, highPrecision: false))
    }

    @Test func yearsAndMonthsNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
        let dates = ["a": day(2024, 7, 1), "b": day(2024, 7, 20), "c": day(2024, 1, 5), "d": day(2019, 3, 3)]
        let years = PhotoFacts.years(dates, calendar: calendar)
        #expect(years.map(\.year) == [2024, 2019])
        #expect(Set(years[0].photos) == ["a", "b", "c"])
        let months = PhotoFacts.months(of: 2024, dates, calendar: calendar)
        #expect(months.map(\.month) == [day(2024, 7, 1), day(2024, 1, 1)])
        #expect(months[0].photos == ["b", "a"])
    }

    @Test func takenBeatsAdded() {
        var facts = PhotoFacts()
        let taken = Date(timeIntervalSince1970: 1_000_000)
        let added = Date(timeIntervalSince1970: 2_000_000)
        facts.photos["a.jpg"] = .init(taken: taken)
        #expect(facts.date(of: "a.jpg", added: added) == taken)
        #expect(facts.date(of: "b.jpg", added: added) == added)
        #expect(facts.needsScan(["a.jpg", "b.jpg"]) == ["b.jpg"])
    }

    @Test func placesGroupByTown() {
        var facts = PhotoFacts()
        let reykjavik = City(name: "Reykjavík", country: "IS")
        facts.photos["a.jpg"] = .init(place: reykjavik)
        facts.photos["b.jpg"] = .init(place: reykjavik)
        facts.photos["c.jpg"] = .init(place: City(name: "Tokyo", country: "JP"))
        facts.photos["d.jpg"] = .init()
        let places = facts.places()
        #expect(places.map(\.place.name) == ["Reykjavík", "Tokyo"])
        #expect(Set(places[0].photos) == ["a.jpg", "b.jpg"])
    }

    @Test func factsRoundTripAsABinaryList() throws {
        var facts = PhotoFacts()
        facts.photos["a.jpg"] = .init(taken: Date(timeIntervalSince1970: 5), latitude: 64.1, longitude: -21.9,
                                      place: City(name: "Reykjavík", country: "IS"), labels: ["food"], faces: [face(1)])
        facts.groupFaces(in: ["a.jpg"])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let back = try PropertyListDecoder().decode(PhotoFacts.self, from: encoder.encode(facts))
        #expect(back == facts)
    }
}

@Suite struct PlaceLookupTests {
    @Test func townsAreNamedOnTheDevice() throws {
        let cities = CityIndex.shared
        #expect(!cities.isEmpty, "The city list ships in the app")
        // A big city wins over the neighbourhood around the corner.
        #expect(cities.nearest(latitude: 35.6595, longitude: 139.7005)?.name == "Tokyo")
        #expect(cities.nearest(latitude: 48.8867, longitude: 2.3431)?.name == "Paris")
        #expect(cities.nearest(latitude: 37.7601, longitude: -122.5096)?.name == "San Francisco")
        // A town next to a big one keeps its own name.
        #expect(cities.nearest(latitude: 37.8044, longitude: -122.2712)?.name == "Oakland")
        // Iceland's far north, 9 km from the nearest village.
        #expect(cities.nearest(latitude: 65.6829, longitude: -17.5489)?.country == "IS")
        // The middle of the Caspian Sea is nowhere.
        #expect(cities.nearest(latitude: 40.0, longitude: 51.5) == nil)
        #expect(cities.nearest(latitude: 64.1466, longitude: -21.9426)?.name == "Reykjavík")
        #expect(cities.nearest(latitude: -33.8688, longitude: 151.2093)?.name == "Sydney")
        #expect(cities.nearest(latitude: 64.0, longitude: 179.9)?.country == "RU" || cities.nearest(latitude: 64.0, longitude: 179.9) == nil)
    }
}

@Suite struct ScannerTests {
    @Test func dateAndPlaceComeFromTheFile() throws {
        // A photo with the EXIF and GPS an iPhone writes.
        let picture = try Fixtures.image("no-face")
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2012:08:08 11:52:11",
                                             kCGImagePropertyExifOffsetTimeOriginal: "+00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 64.1466, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 21.9426, kCGImagePropertyGPSLongitudeRef: "W"],
        ]
        CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(out, nil))
        var facts = PhotoFacts.Photo()
        PhotoScanner.read(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:], into: &facts)
        #expect(facts.taken == Date(timeIntervalSince1970: 1_344_426_731))
        #expect(facts.latitude == 64.1466)
        #expect(facts.longitude == -21.9426)
        #expect(facts.place?.name == "Reykjavík")
    }

    @Test func videoPositionsAndStamps() {
        let place = PhotoScanner.iso6709("+37.7858-122.4064+010.000/")
        #expect(place?.0 == 37.7858)
        #expect(place?.1 == -122.4064)
        #expect(PhotoScanner.iso6709("nothing") == nil)
        // No offset: the iPhone's own time zone.
        #expect(PhotoScanner.exifDate("2024:07:14 18:30:05", offset: "+02:00") == Date(timeIntervalSince1970: 1_720_974_605))
        #expect(PhotoScanner.exifDate("2024:07:14 18:30:05", offset: nil) != nil)
        #expect(PhotoScanner.exifDate("garbage", offset: nil) == nil)
    }

    /// Finds faces in the simulator too: face detection runs there.
    @Test func facesAreFound() async throws {
        var ines = PhotoFacts.Photo()
        await PhotoScanner.look(at: try Fixtures.image("face-ines"), into: &ines)
        #expect(ines.faces.count == 1)
        #expect(ines.faces.first?.box.count == 4)
        #expect(ines.faces.first.map { PhotoFacts.vector($0.print).count } == 768)
        var none = PhotoFacts.Photo()
        await PhotoScanner.look(at: try Fixtures.image("no-face"), into: &none)
        #expect(none.faces.isEmpty)
    }

    /// Labels and face prints need an iPhone: in the simulator Vision's
    /// models return the same answer for every picture.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil))
    func visionTellsFacesApartOnTheIPhone() async throws {
        var ines = PhotoFacts.Photo()
        await PhotoScanner.look(at: try Fixtures.image("face-ines"), into: &ines)
        #expect(ines.labels.contains("people"))

        // The same picture, smaller and cropped differently.
        let original = CIImage(cgImage: try Fixtures.image("face-ines"))
        let moved = original.cropped(to: original.extent.insetBy(dx: 40, dy: 30)).transformed(by: CGAffineTransform(scaleX: 0.8, y: 0.8))
        let again = try #require(CIContext().createCGImage(moved, from: moved.extent))
        var inesAgain = PhotoFacts.Photo()
        await PhotoScanner.look(at: again, into: &inesAgain)

        var leo = PhotoFacts.Photo()
        await PhotoScanner.look(at: try Fixtures.image("face-leo"), into: &leo)

        var facts = PhotoFacts()
        facts.photos = ["ines.jpg": ines, "ines 2.jpg": inesAgain, "leo.jpg": leo]
        facts.groupFaces(in: ["ines.jpg", "ines 2.jpg", "leo.jpg"])
        let people = facts.peopleWithPhotos()
        #expect(people.count == 1)
        #expect(Set(people.first?.photos ?? []) == ["ines.jpg", "ines 2.jpg"])
    }
}
