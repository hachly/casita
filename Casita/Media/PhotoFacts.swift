import Accelerate
import Foundation

/// What Casita worked out about each photo and video in a space, for the
/// automatic albums: when and where it was taken, what is in it, and the
/// faces in it. Worked out on this iPhone and kept inside the space like the
/// albums, so nothing outside the space shows it and nothing is sent anywhere.
struct PhotoFacts: Codable, Equatable, Sendable {
    /// Binary property list: face prints are raw bytes, which JSON would
    /// inflate by a third.
    static let file = "app/photo-facts.plist"
    /// Bumped when the scanner changes, so older facts are worked out again.
    static let scanVersion = 1

    var photos: [String: Photo] = [:]
    var people: [Person] = []

    struct Photo: Codable, Equatable, Sendable {
        var version = PhotoFacts.scanVersion
        /// When it was taken, from the file itself; nil when the file doesn't
        /// say (the date it was added stands in).
        var taken: Date?
        var latitude: Double?
        var longitude: Double?
        /// The town or city nearest the position, from the built-in list.
        var place: City?
        /// Vision's labels that passed the bar, such as "food" or "beach".
        var labels: [String] = []
        var faces: [Face] = []
        /// Whether its faces were put with people yet.
        var grouped = false
    }

    struct Face: Codable, Equatable, Sendable {
        /// Where the face is, as fractions of the picture, origin top left:
        /// x, y, width, height.
        var box: [Float]
        /// Vision's feature print of the face, as Float16s.
        var print: Data
        var person: UUID?
        /// People this face was said not to be; it never joins them again.
        var notPeople: [UUID] = []
    }

    struct Person: Codable, Equatable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var name: String?
    }

    /// Scanned photos whose faces haven't been put with people yet.
    var ungrouped: [String] { photos.filter { !$0.value.grouped }.map(\.key).sorted() }

    /// Photos and videos with no facts yet, or facts from an older scanner.
    func needsScan(_ names: [String]) -> [String] {
        names.filter { (photos[$0]?.version ?? 0) < Self.scanVersion }
    }

    /// Forgets files no longer in the space, and people left with no face.
    mutating func prune(keeping existing: Set<String>) {
        photos = photos.filter { existing.contains($0.key) }
        let seen = Set(photos.values.flatMap { $0.faces.compactMap(\.person) })
        people.removeAll { !seen.contains($0.id) }
    }
}

// MARK: People

extension PhotoFacts {
    /// Two faces closer than this are taken to be one person. Measured on
    /// Vision's revision 2 feature prints of upright, near-frontal face crops:
    /// at 0.6, 93% of the faces grouped together were the same person, and
    /// about half of each person's faces were found. Grouping fewer, surer
    /// faces is the trade: a wrong face is worse than a missing one, which
    /// "Same person" fixes by hand.
    static let sameFace: Float = 0.6

    /// Puts the faces of newly scanned photos with the people they look like.
    /// A face joins the person of the closest face within `sameFace`, never
    /// one already in the same photo and never one it was said not to be. Two
    /// close faces that belong to nobody start a new person.
    mutating func groupFaces(in names: [String]) {
        struct Known { let photo: String; let index: Int; let vector: [Float] }
        var known: [Known] = []
        for (photo, facts) in photos {
            for (i, face) in facts.faces.enumerated() { known.append(Known(photo: photo, index: i, vector: Self.vector(face.print))) }
        }
        for name in names {
            photos[name]?.grouped = true
            guard let faces = photos[name]?.faces else { continue }
            for i in faces.indices where photos[name]?.faces[i].person == nil {
                let face = photos[name]!.faces[i]
                let mine = Self.vector(face.print)
                let taken = Set(photos[name]!.faces.compactMap(\.person))
                var best: (Known, Float)?
                for other in known where other.photo != name {
                    let theirs = photos[other.photo]!.faces[other.index]
                    if let person = theirs.person, taken.contains(person) || face.notPeople.contains(person) { continue }
                    let d = Self.distance(mine, other.vector)
                    if d < Self.sameFace, d < (best?.1 ?? .infinity) { best = (other, d) }
                }
                guard let (match, _) = best else { continue }
                let person: UUID
                if let existing = photos[match.photo]!.faces[match.index].person {
                    person = existing
                } else {
                    let new = Person()
                    people.append(new)
                    person = new.id
                    photos[match.photo]!.faces[match.index].person = person
                }
                photos[name]!.faces[i].person = person
            }
        }
    }

    /// Each person seen in at least `minimum` photos (named people always),
    /// with their photos, most photos first.
    func peopleWithPhotos(minimum: Int = 2) -> [(person: Person, photos: [String])] {
        var byPerson: [UUID: Set<String>] = [:]
        for (photo, facts) in photos {
            for face in facts.faces { if let id = face.person { byPerson[id, default: []].insert(photo) } }
        }
        return people.compactMap { person -> (Person, [String])? in
            let shown = byPerson[person.id] ?? []
            guard shown.count >= minimum || (person.name != nil && !shown.isEmpty) else { return nil }
            return (person, Array(shown))
        }
        .sorted { ($0.1.count, $1.0.name ?? "") > ($1.1.count, $0.0.name ?? "") }
    }

    /// The face that stands for a person: the largest one in a photo (a
    /// video's face comes from a frame its thumbnail doesn't show).
    func cover(of person: UUID) -> (photo: String, box: [Float])? {
        var best: (String, [Float])?
        for (photo, facts) in photos where MediaKind(name: photo) == .image {
            for face in facts.faces where face.person == person {
                if face.box[2] > (best?.1[2] ?? 0) { best = (photo, face.box) }
            }
        }
        return best
    }

    func person(_ id: UUID) -> Person? { people.first { $0.id == id } }

    mutating func name(_ id: UUID, _ name: String) {
        guard let i = people.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        people[i].name = trimmed.isEmpty ? nil : trimmed
    }

    /// "Same person": every face of `other` becomes `person`'s. A name is
    /// kept: `person`'s, or `other`'s when `person` has none.
    mutating func merge(_ other: UUID, into person: UUID) {
        guard other != person, let i = people.firstIndex(where: { $0.id == person }) else { return }
        if people[i].name == nil { people[i].name = self.person(other)?.name }
        for photo in photos.keys {
            for f in photos[photo]!.faces.indices {
                if photos[photo]!.faces[f].person == other { photos[photo]!.faces[f].person = person }
                photos[photo]!.faces[f].notPeople = photos[photo]!.faces[f].notPeople.map { $0 == other ? person : $0 }
            }
        }
        people.removeAll { $0.id == other }
    }

    /// "Not this person": the photo leaves the person and never rejoins.
    mutating func remove(_ photo: String, from person: UUID) {
        guard let faces = photos[photo]?.faces else { return }
        for f in faces.indices where faces[f].person == person {
            photos[photo]!.faces[f].person = nil
            photos[photo]!.faces[f].notPeople.append(person)
        }
        prune(keeping: Set(photos.keys))
    }

    static func packed(_ vector: [Float]) -> Data {
        vector.map(Float16.init).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { $0.bindMemory(to: Float16.self).map(Float.init) }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        return vDSP.distanceSquared(a, b).squareRoot()
    }
}

// MARK: Things

/// The kinds of things an automatic album gathers, each from a few of
/// Vision's labels.
enum Thing: String, CaseIterable, Sendable {
    case food, drinks, dogs, cats, animals, flowers, beaches, mountains, snow, water,
         sunsets, city, cars, documents, screenshots, celebrations, sport, art, babies

    var title: String {
        switch self {
        case .food: "Food"
        case .drinks: "Drinks"
        case .dogs: "Dogs"
        case .cats: "Cats"
        case .animals: "Animals"
        case .flowers: "Flowers"
        case .beaches: "Beaches"
        case .mountains: "Mountains"
        case .snow: "Snow"
        case .water: "Lakes and rivers"
        case .sunsets: "Sunsets"
        case .city: "Cities"
        case .cars: "Cars"
        case .documents: "Documents"
        case .screenshots: "Screenshots"
        case .celebrations: "Celebrations"
        case .sport: "Sport"
        case .art: "Art"
        case .babies: "Babies"
        }
    }

    /// Vision labels (from `ClassifyImageRequest`'s 1,303) that count.
    var labels: Set<String> {
        switch self {
        case .food: ["food", "dessert", "cake", "pizza", "sushi", "salad", "bread", "fruit", "vegetable"]
        case .drinks: ["drink", "coffee", "wine", "beer", "cocktail"]
        case .dogs: ["dog", "canine"]
        case .cats: ["cat", "feline"]
        case .animals: ["animal", "bird", "horse", "fish"]
        case .flowers: ["flower"]
        case .beaches: ["beach", "shore"]
        case .mountains: ["mountain", "hill"]
        case .snow: ["snow", "skiing"]
        case .water: ["waterfall", "lake", "river", "waterways"]
        case .sunsets: ["sunset_sunrise"]
        case .city: ["cityscape", "street"]
        case .cars: ["car", "automobile"]
        case .documents: ["document", "receipt", "handwriting", "whiteboard", "passport", "ticket"]
        case .screenshots: ["screenshot"]
        case .celebrations: ["celebration", "wedding", "fireworks"]
        case .sport: ["sport"]
        case .art: ["art", "painting", "museum"]
        case .babies: ["baby"]
        }
    }

    /// Labels kept from a scan: sure enough (Vision's high-precision bar,
    /// 90% precision) and not a long shot (confidence 0.4 or more; on the
    /// sample photos, a meadow scored "food" 0.17 and a plate of peas 0.49).
    static func keeps(confidence: Float, highPrecision: Bool) -> Bool {
        highPrecision && confidence >= 0.4
    }
}

extension PhotoFacts {
    /// Every kind of thing with at least one photo, in `Thing` order.
    func things() -> [(thing: Thing, photos: [String])] {
        Thing.allCases.compactMap { thing in
            let shown = photos.filter { !thing.labels.isDisjoint(with: $0.value.labels) }.map(\.key)
            return shown.isEmpty ? nil : (thing, shown)
        }
    }
}

// MARK: Timeline and places

extension PhotoFacts {
    /// When a photo was taken, or else when it was added.
    func date(of name: String, added: Date?) -> Date? {
        photos[name]?.taken ?? added
    }

    /// Years, newest first, each with its photos.
    static func years(_ dates: [String: Date], calendar: Calendar = .current) -> [(year: Int, photos: [String])] {
        Dictionary(grouping: dates.keys) { calendar.component(.year, from: dates[$0]!) }
            .map { ($0.key, $0.value) }
            .sorted { $0.0 > $1.0 }
    }

    /// One year's months, newest first, each with its photos newest first.
    static func months(of year: Int, _ dates: [String: Date], calendar: Calendar = .current) -> [(month: Date, photos: [String])] {
        let inYear = dates.filter { calendar.component(.year, from: $0.value) == year }
        return Dictionary(grouping: inYear.keys) { calendar.dateInterval(of: .month, for: dates[$0]!)!.start }
            .map { ($0.key, $0.value.sorted { dates[$0]! > dates[$1]! }) }
            .sorted { $0.0 > $1.0 }
    }

    /// Each place with its photos, most photos first.
    func places() -> [(place: City, photos: [String])] {
        Dictionary(grouping: photos.filter { $0.value.place != nil }.keys) { photos[$0]!.place! }
            .map { ($0.key, $0.value) }
            .sorted { ($0.1.count, $1.0.name) > ($1.1.count, $0.0.name) }
    }
}

extension ReservedStorage {
    func photoFacts(in space: SpaceRef) -> PhotoFacts {
        guard let data = try? readFile(named: PhotoFacts.file, in: space) else { return PhotoFacts() }
        return (try? PropertyListDecoder().decode(PhotoFacts.self, from: data)) ?? PhotoFacts()
    }

    func save(_ facts: PhotoFacts, in space: SpaceRef) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try writeFile(named: PhotoFacts.file, data: try encoder.encode(facts), in: space)
    }

    /// When each file was added to the space.
    func addedDates(in space: SpaceRef) throws -> [String: Date] {
        Dictionary(try state(space).header.files.map { ($0.name, $0.created) }, uniquingKeysWith: { a, _ in a })
    }
}
