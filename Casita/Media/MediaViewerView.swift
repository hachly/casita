import AVFoundation
import AVKit
import PDFKit
import QuickLook
import SwiftUI
import UIKit

/// Shows a space's files one at a time, from memory, and swipes between
/// them: photos and videos page among the space's gallery, documents among
/// its files. Only Office-type files and the share sheet ever get a
/// temporary unlocked copy on disk, removed as soon as it isn't on screen.
struct MediaViewerView: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let item: MediaItem
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [MediaItem]
    @State private var current: String
    @State private var chrome = true
    @State private var zoomed = false
    @State private var shareURL: URL?
    /// Set once the viewer has gone, so a share copy made late is removed.
    @State private var closed = false
    /// The sheet opens from the copy itself, so it never draws before the
    /// copy exists (a sheet opened from a flag came up blank the first time).
    @State private var sharing: ShareFile?
    @State private var confirmDelete: MediaItem?
    @State private var toast: String?

    init(storage: ReservedStorage, space: SpaceRef, item: MediaItem, onDelete: @escaping () -> Void) {
        self.storage = storage
        self.space = space
        self.item = item
        self.onDelete = onDelete
        _items = State(initialValue: [item])
        _current = State(initialValue: item.id)
    }

    private var currentItem: MediaItem { items.first { $0.id == current } ?? item }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TabView(selection: $current) {
                    ForEach(items) { page in
                        MediaPage(
                            storage: storage, space: space, item: page,
                            isCurrent: page.id == current, insets: geo.safeAreaInsets,
                            onZoom: { if page.id == current { zoomed = $0 } },
                            onTap: toggleChrome
                        )
                        .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .scrollDisabled(zoomed)
                .ignoresSafeArea()

                bars
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(.dark)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .interactiveDismissDisabled(zoomed)
        .toast($toast)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.screen")
        .task { await loadSiblings() }
        .onChange(of: current) { _, _ in
            Haptics.play(.select)
            zoomed = false
            // Only pictures hide the bars; anything else keeps its buttons.
            if currentItem.kind != .image, !chrome { withAnimation(Theme.snappy) { chrome = true } }
        }
        .onAppear { closed = false }
        .onDisappear {
            closed = true
            removeShareCopy()
        }
        .sheet(item: $sharing, onDismiss: removeShareCopy) { file in
            ShareSheet(url: file.url)
        }
        .confirmationDialog(
            confirmDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { target in
            Button("Delete", role: .destructive) { Task { await delete(target) } }
        }
    }

    // MARK: Bars

    private var bars: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle(size: 40, fill: Theme.surface))
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("viewer.close")
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .animation(Theme.snappy, value: current)
                Spacer(minLength: 0)
                Color.clear.frame(width: 40, height: 40)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
            HStack {
                Button(action: share) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(CircleButtonStyle(size: 48, fill: Theme.surface))
                    .accessibilityLabel("Share")
                    .accessibilityIdentifier("viewer.share")
                Spacer()
                Button {
                    Haptics.play(.warning)
                    confirmDelete = currentItem
                } label: { Image(systemName: "trash") }
                    .buttonStyle(CircleButtonStyle(size: 48, fill: Theme.surface, tint: Theme.danger))
                    .accessibilityLabel("Delete")
                    .accessibilityIdentifier("viewer.delete")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .opacity(chrome ? 1 : 0)
        .allowsHitTesting(chrome)
    }

    private var title: String {
        if !currentItem.kind.isGalleryItem { return currentItem.name }
        guard items.count > 1, let index = items.firstIndex(where: { $0.id == current }) else { return "" }
        return "\(index + 1) of \(items.count)"
    }

    // MARK: Actions

    private func toggleChrome() {
        withAnimation(Theme.snappy) { chrome.toggle() }
    }

    /// The items to swipe through: the space's gallery for a photo or video,
    /// its files for anything else.
    private func loadSiblings() async {
        guard let all = try? await storage.mediaItems(in: space) else { return }
        let group = all.filter { $0.kind.isGalleryItem == item.kind.isGalleryItem }
        if group.contains(item), group != items { items = group }
    }

    private func share() {
        let target = currentItem
        Task {
            do {
                let data = try await storage.readFile(named: target.name, in: space)
                removeShareCopy()
                let url = try MediaTemp.write(data, named: target.name)
                guard !closed else { return MediaTemp.remove(url) }
                shareURL = url
                sharing = ShareFile(url: url)
            } catch {
                Haptics.play(.error)
                toast = mediaErrorText(error)
            }
        }
    }

    private func removeShareCopy() {
        shareURL.map(MediaTemp.remove)
        shareURL = nil
    }

    private func delete(_ target: MediaItem) async {
        do {
            try await storage.deleteItem(target, in: space)
        } catch {
            Haptics.play(.error)
            toast = mediaErrorText(error)
            return
        }
        Haptics.play(.thud)
        onDelete()
        guard let index = items.firstIndex(of: target), items.count > 1 else {
            dismiss()
            return
        }
        let next = index + 1 < items.count ? items[index + 1] : items[index - 1]
        withAnimation(Theme.smooth) {
            current = next.id
            items.remove(at: index)
        }
    }
}

/// One page of the viewer. Pictures, PDFs and text load when the page comes
/// into view; videos and Office files only while the page is the current
/// one, so at most one video sits in memory and at most one unlocked copy
/// exists.
private struct MediaPage: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let item: MediaItem
    let isCurrent: Bool
    let insets: EdgeInsets
    var onZoom: (Bool) -> Void
    var onTap: () -> Void

    @State private var thumb: UIImage?
    @State private var image: UIImage?
    @State private var text: String?
    @State private var pdf: Data?
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var loader: MemoryAssetLoader?
    @State private var tempURL: URL?
    @State private var failure: String?

    /// Room for the viewer's bars above and below documents and videos.
    /// Pictures fill the screen; everything else also keeps clear of a
    /// system bar down either side.
    private var top: CGFloat { insets.top + 60 }
    private var bottom: CGFloat { insets.bottom + 68 }

    var body: some View {
        ZStack {
            Color.clear
            content
        }
        .contentShape(Rectangle())
        .task { await loadStill() }
        .task(id: isCurrent) { await loadLive() }
        .onDisappear(perform: unloadAll)
    }

    @ViewBuilder private var content: some View {
        if let failure {
            VStack(spacing: 14) {
                GlyphView(glyph: item.kind.isGalleryItem ? .photos : .files, lineWidth: 1.5)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Theme.tertiary)
                Text(failure)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
            .onTapGesture(perform: onTap)
        } else {
            switch item.kind {
            case .image:
                if let image {
                    ZoomableImage(image: image, isCurrent: isCurrent, onZoom: onZoom, onTap: onTap)
                        .transition(.opacity)
                } else if let thumb {
                    still(thumb)
                } else {
                    loading
                }
            case .video:
                if let player {
                    // Held only while it plays; a paused video idles out.
                    VideoPlayer(player: player)
                        .holdsIdleLock(isCurrent && playing)
                        .onReceive(player.publisher(for: \.timeControlStatus)) { playing = $0 == .playing }
                        .padding(EdgeInsets(top: top, leading: insets.leading, bottom: bottom, trailing: insets.trailing))
                        .transition(.opacity)
                } else if let thumb {
                    still(thumb)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(.system(size: 22, weight: .bold))
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                } else {
                    loading
                }
            case .pdf:
                if let pdf {
                    PDFKitView(data: pdf)
                        .padding(EdgeInsets(top: top, leading: insets.leading, bottom: bottom, trailing: insets.trailing))
                } else {
                    loading
                }
            case .text:
                if let text {
                    ScrollView {
                        Text(text)
                            .font(.body.monospaced())
                            .foregroundStyle(Theme.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.gutter)
                    }
                    .contentMargins(.top, top, for: .scrollContent)
                    .contentMargins(.bottom, bottom, for: .scrollContent)
                    // Clear of a bar down the side (a closed iPhone Duo's).
                    .padding(.leading, insets.leading)
                    .padding(.trailing, insets.trailing)
                } else {
                    loading
                }
            case .other:
                if let tempURL {
                    QuickLookView(url: tempURL)
                        .padding(EdgeInsets(top: top, leading: insets.leading, bottom: bottom, trailing: insets.trailing))
                } else {
                    loading
                }
            }
        }
    }

    private func still(_ picture: UIImage) -> some View {
        Image(uiImage: picture)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    private var loading: some View {
        ProgressView().tint(Theme.secondary)
    }

    private func loadStill() async {
        do {
            switch item.kind {
            case .image, .video:
                if thumb == nil, let data = try? await storage.readFile(named: item.thumbName, in: space) {
                    thumb = UIImage(data: data)
                }
                guard item.kind == .image, image == nil else { return }
                let data = try await storage.readFile(named: item.name, in: space)
                guard !Task.isCancelled else { return }
                // Decoded at full size (up to 4096 px), upright, off the main thread.
                guard let decoded = await Thumbnail.display(data: data, maxPixels: 4096) else {
                    failure = "Can't show this picture"
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) { image = decoded }
            case .pdf:
                guard pdf == nil else { return }
                pdf = try await storage.readFile(named: item.name, in: space)
            case .text:
                guard text == nil else { return }
                text = String(decoding: try await storage.readFile(named: item.name, in: space), as: UTF8.self)
            case .other:
                break
            }
        } catch {
            failure = mediaErrorText(error)
        }
    }

    private func loadLive() async {
        guard isCurrent else { unloadLive(); return }
        do {
            switch item.kind {
            case .video:
                guard player == nil else { return }
                // The whole video is held in memory; add a ranged
                // readFile to Storage if long videos ever matter.
                let data = try await storage.readFile(named: item.name, in: space)
                guard !Task.isCancelled else { return }
                let loader = MemoryAssetLoader(data: data, contentType: item.utType.identifier)
                let asset = AVURLAsset(url: URL(string: "casita-media://v/\(UUID().uuidString).\((item.name as NSString).pathExtension)")!)
                asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "casita.media.loader"))
                self.loader = loader
                withAnimation(.easeOut(duration: 0.2)) { player = AVPlayer(playerItem: AVPlayerItem(asset: asset)) }
            case .other:
                guard tempURL == nil else { return }
                let data = try await storage.readFile(named: item.name, in: space)
                guard !Task.isCancelled else { return }
                tempURL = try MediaTemp.write(data, named: item.name)
            default:
                break
            }
        } catch {
            failure = mediaErrorText(error)
        }
    }

    /// A page out of sight keeps only its thumbnail: a full picture is tens
    /// of megabytes once decoded.
    private func unloadAll() {
        unloadLive()
        image = nil
        pdf = nil
        text = nil
    }

    /// Lets go of the video and removes the unlocked copy.
    private func unloadLive() {
        player?.pause()
        player = nil
        loader = nil
        if let tempURL {
            MediaTemp.remove(tempURL)
            self.tempURL = nil
        }
    }
}

// MARK: Zoom

/// A picture that pinches and double-taps to zoom, and taps once to show or
/// hide the viewer's bars.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let isCurrent: Bool
    var onZoom: (Bool) -> Void
    var onTap: () -> Void

    func makeUIView(context: Context) -> ZoomingImageView {
        ZoomingImageView(image: image)
    }

    func updateUIView(_ view: ZoomingImageView, context: Context) {
        view.onZoom = onZoom
        view.onTap = onTap
        view.setImage(image)
        if !isCurrent { view.resetZoom() }
    }
}

final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    var onZoom: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    private var fittedFor: CGSize = .zero
    private var isZoomed = false

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        // At 1× nothing scrolls, so sideways swipes reach the pager.
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        imageView.image = image
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        single.require(toFail: double)
        addGestureRecognizer(single)

        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = "Photo"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedFor = .zero
        setNeedsLayout()
    }

    func resetZoom() {
        if zoomScale != minimumZoomScale { setZoomScale(minimumZoomScale, animated: false) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedFor { fit() }
    }

    /// Sizes the picture to fit the page at 1× and centres it.
    private func fit() {
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }
        fittedFor = bounds.size
        minimumZoomScale = 1
        zoomScale = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        // Rounded down: content a hair larger than the page would scroll and
        // swallow the pager's swipes.
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        // Far enough in to see the picture's own pixels, and never less than 3×.
        let native = image.size.width * image.scale / max(1, size.width * traitCollection.displayScale)
        maximumZoomScale = max(3, min(native * 1.5, 8))
        centerImage()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        report()
    }

    private func centerImage() {
        let size = imageView.frame.size
        let x = max(0, (bounds.width - size.width) / 2)
        let y = max(0, (bounds.height - size.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        report()
    }

    private func report() {
        let zoomed = zoomScale > minimumZoomScale + 0.01
        guard zoomed != isZoomed else { return }
        isZoomed = zoomed
        onZoom?(zoomed)
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        Haptics.play(.soft)
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func singleTapped() {
        onTap?()
    }
}

// MARK: Players and previews

/// Serves a video to AVFoundation straight from memory; nothing touches disk.
final class MemoryAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let data: Data
    private let contentType: String

    init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = request.dataRequest {
            let start = Int(dataRequest.requestedOffset)
            let available = data.count - start
            let length = dataRequest.requestsAllDataToEndOfResource ? available : min(Int(dataRequest.requestedLength), available)
            if start >= 0, length > 0 {
                dataRequest.respond(with: data.subdata(in: start..<start + length))
            }
        }
        request.finishLoading()
        return true
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .black
        view.pageShadowsEnabled = false
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}

/// QuickLook for Office-type files, fed one protected temporary copy.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}

struct ShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // iOS can't hide Save to Casita here (only Apple's own activities can
        // be excluded); the extension refuses while a space is open instead.
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
