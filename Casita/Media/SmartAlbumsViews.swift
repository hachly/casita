import SwiftUI

/// A titled row of albums that scrolls sideways.
struct Shelf<Content: View>: View {
    let title: String
    let id: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
                .padding(.horizontal, Theme.gutter)
                .accessibilityIdentifier(id)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) { content() }
                    .padding(.horizontal, Theme.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// "Sorting 12 of 40 on this iPhone", while photos are still being looked at.
struct SortingNote: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().tint(Theme.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sorting photos").font(.subheadline.weight(.semibold))
                Text("\(done) of \(total), on this iPhone").font(.caption).foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("albums.sorting")
    }
}

/// A person on the People shelf: their face, and their name or "Add a name".
struct PersonBubble: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let facts: PhotoFacts
    let person: PhotoFacts.Person
    let count: Int

    var body: some View {
        VStack(spacing: 6) {
            FaceAvatar(storage: storage, space: space, cover: facts.cover(of: person.id))
                .frame(width: 88, height: 88)
            Text(person.name ?? "Add a name")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(person.name == nil ? Theme.secondary : Theme.primary)
                .lineLimit(1)
            Text(counted(count, "item", "items")).font(.caption).foregroundStyle(Theme.tertiary)
        }
        .frame(width: 96)
    }
}

/// A round crop of one face, cut from the photo in memory.
struct FaceAvatar: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let cover: (photo: String, box: [Float])?
    @State private var image: UIImage?

    var body: some View {
        Circle().fill(Theme.surface)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: "person.fill").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
                }
            }
            .clipShape(Circle())
            .task(id: cover?.photo) {
                guard let cover, let data = try? await storage.readFile(named: cover.photo, in: space) else { return }
                let face = await Self.crop(data, box: cover.box)
                withAnimation(.easeOut(duration: 0.25)) { image = face }
            }
    }

    /// The face's box doubled, kept square and inside the picture.
    static func crop(_ data: Data, box: [Float]) async -> UIImage? {
        guard box.count == 4, let picture = await Thumbnail.display(data: data, maxPixels: PhotoScanner.lookSize)?.cgImage else { return nil }
        let w = CGFloat(picture.width), h = CGFloat(picture.height)
        let face = CGRect(x: CGFloat(box[0]) * w, y: CGFloat(box[1]) * h, width: CGFloat(box[2]) * w, height: CGFloat(box[3]) * h)
        let side = min(max(face.width, face.height) * 2, w, h)
        let x = min(max(face.midX - side / 2, 0), w - side)
        let y = min(max(face.midY - side / 2, 0), h - side)
        return picture.cropping(to: CGRect(x: x, y: y, width: side, height: side)).map(UIImage.init)
    }
}

/// "Same person as…": the other people, to join with this one.
struct PersonPicker: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let smart: SmartAlbums
    let except: UUID
    var onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Three across on a phone, more on a wide screen.
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                let others = smart.people.filter { $0.person.id != except }
                if others.isEmpty {
                    Text("No one else yet.").foregroundStyle(Theme.secondary).padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(others.enumerated()), id: \.element.person.id) { index, entry in
                        Button {
                            Haptics.play(.success)
                            onPick(entry.person.id)
                            dismiss()
                        } label: {
                            PersonBubble(storage: storage, space: space, facts: smart.facts, person: entry.person, count: entry.items.count)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.95))
                        .accessibilityIdentifier("personPicker.\(index)")
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle("Same person as…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}
