import SwiftUI

/// Which album a grid shows: one the person made, every video, or one of
/// the automatic albums.
enum AlbumRoute: Hashable {
    case album(UUID)
    case videos
    case person(UUID)
    /// A `City.id`.
    case place(String)
    case thing(Thing)
    case year(Int)
}

/// The automatic albums, worked out from a space's photo facts and library.
struct SmartAlbums {
    let library: [MediaItem]
    let facts: PhotoFacts
    /// When each item was taken, or else added.
    let dates: [String: Date]
    private let timelineDates: [String: Date]
    private let byName: [String: MediaItem]

    init(library: [MediaItem], facts: PhotoFacts, added: [String: Date], allowsNewTimeline: Bool = true) {
        self.library = library
        self.facts = facts
        byName = Dictionary(library.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        dates = Dictionary(library.compactMap { item in facts.date(of: item.name, added: added[item.name]).map { (item.name, $0) } },
                           uniquingKeysWith: { a, _ in a })
        timelineDates = allowsNewTimeline ? dates : dates.filter { facts.photos[$0.key] != nil }
    }

    /// The items with these names, newest first.
    func items(_ names: [String]) -> [MediaItem] {
        names.compactMap { byName[$0] }.sorted { (dates[$0.name] ?? .distantPast) > (dates[$1.name] ?? .distantPast) }
    }

    var people: [(person: PhotoFacts.Person, items: [MediaItem])] {
        facts.peopleWithPhotos().map { ($0.person, items($0.photos)) }.filter { $0.1.count > 0 }
    }

    var places: [(place: City, items: [MediaItem])] {
        facts.places().map { ($0.place, items($0.photos)) }.filter { !$0.1.isEmpty }
    }

    var things: [(thing: Thing, items: [MediaItem])] {
        facts.things().map { ($0.thing, items($0.photos)) }.filter { !$0.1.isEmpty }
    }

    var years: [(year: Int, items: [MediaItem])] {
        PhotoFacts.years(timelineDates).map { ($0.year, items($0.photos)) }
    }

    func title(of route: AlbumRoute, albums: Albums) -> String {
        switch route {
        case .album(let id): albums.albums.first { $0.id == id }?.name ?? "Album"
        case .videos: "Videos"
        case .person(let id): facts.person(id)?.name ?? "Someone"
        case .place(let id): facts.places().first { $0.place.id == id }?.place.name ?? "Place"
        case .thing(let thing): thing.title
        case .year(let year): String(year)
        }
    }

    /// What the album holds, in groups: one for most, a year's months for
    /// a year.
    func sections(of route: AlbumRoute, albums: Albums) -> [(title: String?, items: [MediaItem])] {
        switch route {
        case .album(let id):
            return [(nil, (albums.albums.first { $0.id == id }?.items ?? []).compactMap { byName[$0] })]
        case .videos:
            return [(nil, library.filter { $0.kind == .video })]
        case .person(let id):
            return [(nil, people.first { $0.person.id == id }?.items ?? [])]
        case .place(let id):
            return [(nil, places.first { $0.place.id == id }?.items ?? [])]
        case .thing(let thing):
            return [(nil, things.first { $0.thing == thing }?.items ?? [])]
        case .year(let year):
            return PhotoFacts.months(of: year, timelineDates).map { ($0.month.formatted(.dateTime.month(.wide)), items($0.photos)) }
        }
    }
}

/// The Albums side of Photos: the person's own albums and the videos, then
/// the automatic ones: people, places, things and years.
struct AlbumsGrid: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let albums: Albums
    let smart: SmartAlbums
    /// Photos still being looked at, if any: done and total.
    let sorting: (done: Int, total: Int)?
    var onOpen: (AlbumRoute) -> Void
    var onNew: () -> Void

    /// Two across on a phone, more on a wide screen.
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var videos: [MediaItem] { smart.library.filter { $0.kind == .video } }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            LazyVGrid(columns: columns, spacing: 16) {
                Button(action: onNew) {
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .fill(Theme.surface)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Image(systemName: "plus").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.secondary))
                        Text("New album").font(.subheadline.weight(.semibold))
                        Text(" ").font(.caption)
                    }
                }
                .buttonStyle(PressableButtonStyle(scale: 0.97))
                .accessibilityIdentifier("albums.new")
                if !videos.isEmpty {
                    AlbumCard(storage: storage, space: space, name: "Videos", detail: counted(videos.count, "item", "items"), cover: videos.first,
                              id: "albums.card.videos") { onOpen(.videos) }
                }
                ForEach(albums.albums) { album in
                    let items = album.items.compactMap { name in smart.library.first { $0.name == name } }
                    AlbumCard(storage: storage, space: space, name: album.name, detail: counted(items.count, "item", "items"), cover: items.first,
                              id: "albums.card.\(album.name)") { onOpen(.album(album.id)) }
                }
            }
            .padding(.horizontal, Theme.gutter)

            if let sorting {
                SortingNote(done: sorting.done, total: sorting.total)
                    .padding(.horizontal, Theme.gutter)
            }
            let people = smart.people
            if !people.isEmpty {
                Shelf(title: "People", id: "albums.section.people") {
                    ForEach(Array(people.enumerated()), id: \.element.person.id) { index, entry in
                        Button { onOpen(.person(entry.person.id)) } label: {
                            PersonBubble(storage: storage, space: space, facts: smart.facts, person: entry.person, count: entry.items.count)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.95))
                        .accessibilityIdentifier("albums.person.\(index)")
                    }
                }
            }
            let places = smart.places
            if !places.isEmpty {
                Shelf(title: "Places", id: "albums.section.places") {
                    ForEach(places, id: \.place) { entry in
                        AlbumCard(storage: storage, space: space, name: entry.place.name,
                                  detail: "\(entry.place.countryName) · \(entry.items.count)", cover: entry.items.first,
                                  id: "albums.place.\(entry.place.name)") { onOpen(.place(entry.place.id)) }
                            .frame(width: 150)
                    }
                }
            }
            let things = smart.things
            if !things.isEmpty {
                Shelf(title: "Things", id: "albums.section.things") {
                    ForEach(things, id: \.thing) { entry in
                        AlbumCard(storage: storage, space: space, name: entry.thing.title, detail: counted(entry.items.count, "item", "items"),
                                  cover: entry.items.first, id: "albums.thing.\(entry.thing.rawValue)") { onOpen(.thing(entry.thing)) }
                            .frame(width: 150)
                    }
                }
            }
            let years = smart.years
            if !years.isEmpty {
                Shelf(title: "Timeline", id: "albums.section.timeline") {
                    ForEach(years, id: \.year) { entry in
                        AlbumCard(storage: storage, space: space, name: String(entry.year), detail: counted(entry.items.count, "item", "items"),
                                  cover: entry.items.first, id: "albums.year.\(entry.year)") { onOpen(.year(entry.year)) }
                            .frame(width: 150)
                    }
                }
            }
            if !smart.library.isEmpty {
                Text("Casita sorts your photos on this iPhone. Nothing about them leaves it.")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, Theme.gutter)
                    .accessibilityIdentifier("albums.onDevice")
            }
        }
    }
}

/// One album's square: its cover, name and count.
struct AlbumCard: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let name: String
    let detail: String
    let cover: MediaItem?
    let id: String
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let cover {
                        ThumbnailCell(storage: storage, space: space, item: cover)
                    } else {
                        Theme.surface.aspectRatio(1, contentMode: .fit)
                            .overlay(GlyphView(glyph: .photos, lineWidth: 1.6).frame(width: 28, height: 28).foregroundStyle(Theme.tertiary))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .accessibilityIdentifier(id)
    }
}

/// One album: its photos and videos. The person's own albums take more from
/// the library and are renamed or deleted (never the photos themselves); a
/// person is named, joined with another, or told a photo isn't them.
struct AlbumView: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let route: AlbumRoute
    let smart: SmartAlbums
    @Binding var albums: Albums
    @Binding var facts: PhotoFacts
    var onChange: () -> Void
    var onFactsChange: () -> Void
    var onLibraryChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: MediaItem?
    @State private var choosing = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var naming = false
    @State private var merging = false

    /// Three across on a phone, more on a wide screen.
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 2)]

    private var album: Albums.Album? {
        guard case .album(let id) = route else { return nil }
        return albums.albums.first { $0.id == id }
    }

    private var personID: UUID? {
        guard case .person(let id) = route else { return nil }
        return id
    }

    private var title: String { smart.title(of: route, albums: albums) }
    private var sections: [(title: String?, items: [MediaItem])] { smart.sections(of: route, albums: albums) }
    private var count: Int { sections.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: title, detail: count == 0 ? nil : counted(count, "item", "items"))
                    .padding(.horizontal, Theme.gutter)
                if let personID, facts.person(personID)?.name == nil {
                    Button { newName = ""; naming = true } label: {
                        Label("Add a name", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(Capsule().fill(Theme.raised))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.horizontal, Theme.gutter)
                    .accessibilityIdentifier("person.addName")
                }
                if count == 0, album != nil {
                    EmptyStateView(glyph: .photos, line: "Nothing in this album yet.") {
                        Button("Add photos") { choosing = true }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("album.empty.add")
                    }
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 60)
                }
                let offsets = sections.indices.map { i in sections[..<i].reduce(0) { $0 + $1.items.count } }
                ForEach(Array(sections.enumerated()), id: \.offset) { s, section in
                    if let heading = section.title {
                        Text(heading).font(.title3.weight(.semibold))
                            .padding(.horizontal, Theme.gutter)
                            .padding(.top, s == 0 ? 0 : 10)
                            .accessibilityIdentifier("album.section.\(heading)")
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            cell(item, index: offsets[s] + index)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album.screen")
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .collapsingTitle(title, readable: false)
        .toolbar {
            if let album {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = album.name; renaming = true } label: { Label("Rename album", systemImage: "pencil") }
                            .accessibilityIdentifier("album.rename")
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete album", systemImage: "trash") }
                            .accessibilityIdentifier("album.delete")
                    } label: { CircleIcon(symbol: "ellipsis") }
                    .accessibilityLabel("Album options")
                    .accessibilityIdentifier("album.menu")
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { choosing = true } label: { Image(systemName: "plus") }
                        .buttonStyle(CircleButtonStyle(size: 38, fill: Theme.primary, tint: .black))
                        .accessibilityLabel("Add to album")
                        .accessibilityIdentifier("album.add")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if let personID {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newName = facts.person(personID)?.name ?? ""; naming = true } label: {
                            Label(facts.person(personID)?.name == nil ? "Add a name" : "Rename", systemImage: "pencil")
                        }
                        .accessibilityIdentifier("person.rename")
                        Button { merging = true } label: { Label("Same person as…", systemImage: "person.2") }
                            .accessibilityIdentifier("person.merge")
                    } label: { CircleIcon(symbol: "ellipsis") }
                    .accessibilityLabel("Person options")
                    .accessibilityIdentifier("person.menu")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .sheet(isPresented: $choosing) {
            PhotoChooser(storage: storage, space: space, library: smart.library, already: Set(album?.items ?? [])) { names in
                guard let album else { return }
                albums.add(names, to: album.id)
                onChange()
            }
        }
        .sheet(isPresented: $merging) {
            if let personID {
                PersonPicker(storage: storage, space: space, smart: smart, except: personID) { other in
                    facts.merge(other, into: personID)
                    onFactsChange()
                }
            }
        }
        .fullScreenCover(item: $selected) { item in
            MediaViewerView(storage: storage, space: space, item: item) { onLibraryChange() }
        }
        .alert("Rename album", isPresented: $renaming) {
            TextField("Name", text: $newName)
                .autocorrectionDisabled()
            Button("Rename") {
                guard let album else { return }
                albums.rename(album.id, to: newName)
                onChange()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Who is this?", isPresented: $naming) {
            TextField("Name", text: $newName)
                .autocorrectionDisabled()
            Button("Save") {
                guard let personID else { return }
                facts.name(personID, newName)
                onFactsChange()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(title)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete album", role: .destructive) {
                guard let album else { return }
                albums.delete(album.id)
                onChange()
                dismiss()
            }
        } message: {
            Text("The photos and videos stay in Photos.")
        }
        .onChange(of: count) { _, new in
            // A person left with no photos is gone.
            if new == 0, personID != nil { dismiss() }
        }
    }

    private func cell(_ item: MediaItem, index: Int) -> some View {
        Button { selected = item } label: {
            ThumbnailCell(storage: storage, space: space, item: item)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .contextMenu {
            if let album {
                Button(role: .destructive) {
                    albums.remove(item.name, from: album.id)
                    onChange()
                } label: { Label("Remove from album", systemImage: "minus.circle") }
            }
            if let personID {
                Button(role: .destructive) {
                    facts.remove(item.name, from: personID)
                    onFactsChange()
                } label: { Label("Not \(facts.person(personID)?.name ?? "this person")", systemImage: "person.crop.circle.badge.xmark") }
            }
        }
        .accessibilityLabel(item.kind == .video ? "Video" : "Photo")
        .accessibilityIdentifier("album.cell.\(index)")
    }
}

/// Picks photos and videos from the library to add to an album.
struct PhotoChooser: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let library: [MediaItem]
    /// Already in the album: shown, but not picked again.
    let already: Set<String>
    var onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String] = []

    /// Three across on a phone, more on a wide screen.
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(library.enumerated()), id: \.element.id) { index, item in
                        let on = picked.contains(item.name)
                        let inAlbum = already.contains(item.name)
                        Button {
                            guard !inAlbum else { return }
                            Haptics.play(.select)
                            if on { picked.removeAll { $0 == item.name } } else { picked.append(item.name) }
                        } label: {
                            ThumbnailCell(storage: storage, space: space, item: item)
                                .opacity(inAlbum ? 0.35 : 1)
                                .overlay(alignment: .topTrailing) {
                                    if on || inAlbum {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(.white, inAlbum ? Theme.raised : Color.black)
                                            .padding(6)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("chooser.cell.\(index)")
                    }
                }
                .padding(2)
            }
            .background(Theme.background)
            .navigationTitle(picked.isEmpty ? "Add to album" : "\(picked.count) chosen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(picked)
                        Haptics.play(.success)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                    .accessibilityIdentifier("chooser.add")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}

/// "Add to album" for one photo or video: an album, or a new one.
struct AlbumPicker: View {
    @Binding var albums: Albums
    let item: MediaItem
    var onAdded: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button { naming = true } label: { Label("New album", systemImage: "plus") }
                    .accessibilityIdentifier("albumPicker.new")
                ForEach(albums.albums) { album in
                    Button { add(to: album) } label: {
                        HStack {
                            Text(album.name)
                            Spacer()
                            if album.items.contains(item.name) { Image(systemName: "checkmark").foregroundStyle(Theme.secondary) }
                        }
                    }
                    .accessibilityIdentifier("albumPicker.album.\(album.name)")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add to album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .tint(.white)
        .alert("New album", isPresented: $naming) {
            TextField("Name", text: $name)
                .autocorrectionDisabled()
            Button("Create") { add(to: albums.create(name)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func add(to album: Albums.Album) {
        albums.add([item.name], to: album.id)
        Haptics.play(.success)
        onAdded(albums.albums.first { $0.id == album.id }?.name ?? album.name)
        dismiss()
    }
}
