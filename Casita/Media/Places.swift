import Foundation

/// A town or city from the built-in list.
struct City: Codable, Hashable, Sendable {
    let name: String
    /// ISO country code, such as "IS".
    let country: String

    var countryName: String { Locale.current.localizedString(forRegionCode: country) ?? country }
    var id: String { "\(name)|\(country)" }
}

/// Names the place a photo was taken without asking anyone: Apple's
/// geocoders send the coordinates to Apple, so Casita carries its own list
/// instead, every town of 1,000 people or more from GeoNames (CC BY 4.0,
/// trimmed to name, country, position and population by
/// `Support/make-cities.py`).
final class CityIndex: Sendable {
    static let shared = CityIndex(url: Bundle.main.url(forResource: "cities", withExtension: "tsv"))

    private struct Entry: Sendable {
        let city: City
        let latitude: Double
        let longitude: Double
        /// How far the place reaches, in km: bigger places reach further.
        let reach: Double
    }

    private let entries: [Entry]
    /// Entries by 1° square, for looking only nearby.
    private let squares: [Int: [Int]]
    /// Further than this from any town, a photo has no place.
    static let farthest = 50.0

    init(url: URL?) {
        var entries: [Entry] = []
        var squares: [Int: [Int]] = [:]
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 5, let lat = Double(parts[2]), let lon = Double(parts[3]), let people = Double(parts[4]) else { continue }
            squares[Self.square(lat, lon), default: []].append(entries.count)
            // 0.01·√population: 1,000 people reach 0.3 km, 100,000 reach
            // 3 km, 1 million 10 km; capped at 25 km.
            entries.append(Entry(city: City(name: String(parts[0]), country: String(parts[1])), latitude: lat, longitude: lon,
                                 reach: min(0.01 * people.squareRoot(), 25)))
        }
        self.entries = entries
        self.squares = squares
    }

    var isEmpty: Bool { entries.isEmpty }

    /// The biggest place whose reach covers the spot, so a photo in Shibuya
    /// is "Tokyo", not the neighbourhood around the corner; else the nearest
    /// place within `farthest`.
    func nearest(latitude: Double, longitude: Double) -> City? {
        let lonSquares = Int((1 / max(cos(latitude * .pi / 180), 0.2)).rounded(.up))
        var covering: Entry?
        var closest: (Entry, Double)?
        for dLat in -1...1 {
            for dLon in -lonSquares...lonSquares {
                for i in squares[Self.square(latitude + Double(dLat), longitude + Double(dLon))] ?? [] {
                    let entry = entries[i]
                    let km = Self.km(latitude, longitude, entry.latitude, entry.longitude)
                    if km <= entry.reach, entry.reach > (covering?.reach ?? 0) { covering = entry }
                    if km < (closest?.1 ?? .infinity) { closest = (entry, km) }
                }
            }
        }
        if let covering { return covering.city }
        guard let (entry, km) = closest, km <= Self.farthest else { return nil }
        return entry.city
    }

    private static func square(_ lat: Double, _ lon: Double) -> Int {
        var lon = lon
        if lon >= 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return Int((lat + 90).rounded(.down)) * 360 + Int((lon + 180).rounded(.down))
    }

    /// Distance on a flat map, good enough at town scale.
    static func km(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        var dLon = abs(lon1 - lon2)
        if dLon > 180 { dLon = 360 - dLon }
        return hypot(lat1 - lat2, dLon * cos(lat1 * .pi / 180)) * 111.2
    }
}
