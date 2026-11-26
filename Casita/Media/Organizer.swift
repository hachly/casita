import Foundation

/// A space's albums: names and the photos and videos in each, by file name.
/// Kept inside the space as one of Casita's own files, so nothing outside the
/// space shows them, and a photo stays one file whatever albums it is in.
struct Albums: Codable, Equatable, Sendable {
    struct Album: Codable, Equatable, Identifiable, Hashable, Sendable {
        var id = UUID()
        var name: String
        /// File names, newest added first.
        var items: [String] = []
    }

    static let file = "app/albums.json"
    var albums: [Album] = []

    @discardableResult
    mutating func create(_ name: String) -> Album {
        let album = Album(name: Self.clean(name, otherwise: "Album"))
        albums.insert(album, at: 0)
        return album
    }

    mutating func rename(_ id: UUID, to name: String) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[i].name = Self.clean(name, otherwise: albums[i].name)
    }

    mutating func delete(_ id: UUID) {
        albums.removeAll { $0.id == id }
    }

    /// Adds what isn't there yet, at the front.
    mutating func add(_ names: [String], to id: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        let new = names.filter { !albums[i].items.contains($0) }
        albums[i].items.insert(contentsOf: new, at: 0)
    }

    mutating func remove(_ name: String, from id: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[i].items.removeAll { $0 == name }
    }

    /// Forgets files no longer in the space.
    mutating func prune(keeping existing: Set<String>) {
        for i in albums.indices { albums[i].items.removeAll { !existing.contains($0) } }
    }

    /// A trimmed name, or `fallback` when nothing is left.
    static func clean(_ name: String, otherwise fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// A space's folders for Files: paths such as "Work" and "Work/Taxes", and
/// which folder each file is in (none means the top). Like albums, an index
/// kept inside the space; the files themselves never move.
struct Folders: Codable, Equatable, Sendable {
    static let file = "app/folders.json"
    var folders: [String] = []
    /// File name to folder path.
    var placement: [String: String] = [:]

    /// The folders directly inside `parent` (nil: the top), by name.
    func subfolders(of parent: String?) -> [String] {
        folders.filter { Self.parent(of: $0) == parent }.sorted { Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending }
    }

    func isFile(_ name: String, in folder: String?) -> Bool {
        placement[name] == folder
    }

    /// Files anywhere under `folder`, its own and its subfolders'.
    func files(under folder: String) -> [String] {
        placement.filter { $0.value == folder || $0.value.hasPrefix(folder + "/") }.map(\.key).sorted()
    }

    /// Makes a folder in `parent`, renamed "Name 2" if the name is taken.
    @discardableResult
    mutating func create(_ name: String, in parent: String?) -> String {
        // A slash would start a folder of its own.
        let base = Albums.clean(name.replacingOccurrences(of: "/", with: "-"), otherwise: "Folder")
        var candidate = base, n = 2
        while folders.contains(Self.join(parent, candidate)) { candidate = "\(base) \(n)"; n += 1 }
        let path = Self.join(parent, candidate)
        folders.append(path)
        return path
    }

    mutating func move(_ file: String, to folder: String?) {
        placement[file] = folder
    }

    /// Renames the folder at `path`; what's inside moves with it.
    @discardableResult
    mutating func rename(_ path: String, to name: String) -> String {
        let clean = Albums.clean(name.replacingOccurrences(of: "/", with: "-"), otherwise: Self.name(of: path))
        let new = Self.join(Self.parent(of: path), clean)
        guard new != path, !folders.contains(new) else { return path }
        func moved(_ p: String) -> String { p == path ? new : p.hasPrefix(path + "/") ? new + p.dropFirst(path.count) : p }
        folders = folders.map(moved)
        placement = placement.mapValues(moved)
        return new
    }

    /// Removes the folder and everything under it; returns the files that
    /// were inside, for deleting.
    mutating func delete(_ path: String) -> [String] {
        let inside = files(under: path)
        folders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        for file in inside { placement[file] = nil }
        return inside
    }

    /// Forgets files no longer in the space.
    mutating func prune(keeping existing: Set<String>) {
        placement = placement.filter { existing.contains($0.key) }
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func parent(of path: String) -> String? {
        guard let cut = path.lastIndex(of: "/") else { return nil }
        return String(path[..<cut])
    }

    static func join(_ parent: String?, _ name: String) -> String {
        parent.map { "\($0)/\(name)" } ?? name
    }
}

extension ReservedStorage {
    /// One of a space's indexes, or an empty one when it was never written.
    func index<T: Codable & Sendable>(_ type: T.Type, file: String, in space: SpaceRef, empty: T) -> T {
        guard let data = try? readFile(named: file, in: space) else { return empty }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? empty
    }

    func saveIndex<T: Codable & Sendable>(_ value: T, file: String, in space: SpaceRef) throws {
        try writeFile(named: file, data: try JSONEncoder().encode(value), in: space)
    }
}
