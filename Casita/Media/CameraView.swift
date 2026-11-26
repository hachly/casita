import AVFoundation
import Synchronization
import SwiftUI
import UIKit

/// Casita's own camera, for photos and videos. Shots go straight into the
/// space, never through the Photos library, and carry no location. Works pushed from the Camera
/// tile (the bar is hidden; Close pops) and presented over Photos.
struct CameraView: View {
    let storage: ReservedStorage
    let space: SpaceRef

    @Environment(Entitlements.self) private var entitlements
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom

    /// Made in `start()`, not here: a view's initializer runs many times.
    @State private var camera: CameraController?
    @State private var phase: Phase = .starting
    @State private var position: AVCaptureDevice.Position = .back
    @State private var canFlip = false
    @State private var rotation: AVCaptureDevice.RotationCoordinator?
    /// True from shutter press until the photo is in memory. A second press
    /// meanwhile does nothing.
    @State private var capturing = false
    @State private var flipping = false
    @State private var flipTurns = 0
    @State private var flashes = 0
    /// Saves run one after another, so two shots in the same second can't
    /// pick the same name.
    @State private var saving: Task<Void, Never>?
    /// This visit's shots that are still in the space, oldest first.
    @State private var shots: [Shot] = []
    @State private var viewing: MediaItem?
    @State private var showPaywall = false
    @State private var toast: String?
    @State private var mode: CaptureMode = .photo
    /// When the video being recorded started; nil when not recording.
    @State private var recordingSince: Date?
    /// True while switching modes or finishing a recording.
    @State private var settling = false

    enum CaptureMode { case photo, video }

    enum Phase: Equatable {
        case starting, running
        case unavailable(CameraUnavailable)
    }

    struct Shot: Identifiable {
        let item: MediaItem
        let image: UIImage?
        var id: String { item.id }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if case .unavailable(let reason) = phase {
                unavailable(reason)
            } else {
                WideReader { split in
                    if let split {
                        // A wide screen: the viewfinder on the leading half,
                        // the switch and the shutter on the trailing half.
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                topBar
                                viewfinder
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 16)
                            }
                            .frame(width: split)
                            VStack(spacing: 0) {
                                Spacer(minLength: 12)
                                modePicker
                                    .padding(.bottom, 14)
                                controls
                                Spacer(minLength: 12)
                            }
                            .column()
                        }
                    } else {
                        VStack(spacing: 0) {
                            topBar
                            viewfinder
                                .padding(.top, 4)
                            Spacer(minLength: 12)
                            modePicker
                                .padding(.bottom, 14)
                            controls
                                .padding(.bottom, 18)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if case .unavailable = phase { closeButton.padding(.leading, 16).padding(.top, 8) }
        }
        .foregroundStyle(Theme.primary)
        .statusBarHidden()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .preferredColorScheme(.dark)
        .paywall(isPresented: $showPaywall, reason: .items)
        .fullScreenCover(item: $viewing) { item in
            MediaViewerView(storage: storage, space: space, item: item) {
                Task { await pruneShots() }
            }
            .navigationTransition(.zoom(sourceID: "camera.last", in: zoom))
        }
        .onChange(of: viewing) { _, now in
            // Nothing to see behind the viewer: rest the camera meanwhile.
            if now == nil { camera?.resume() } else { camera?.stop() }
        }
        .task { await start() }
        .onAppear { if phase == .running, viewing == nil { camera?.resume() } }
        .onDisappear { camera?.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.screen")
        // Framing a shot is not a touch; the camera never idles out. A shot
        // open over it locks like any other photo.
        .holdsIdleLock(viewing == nil)
    }

    // MARK: Parts

    private var closeButton: some View {
        Button { dismiss() } label: { Image(systemName: "xmark") }
            .buttonStyle(CircleButtonStyle(size: 40, fill: Theme.surface))
            .accessibilityLabel("Close")
            .accessibilityIdentifier("camera.close")
    }

    private var topBar: some View {
        HStack {
            closeButton
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var viewfinder: some View {
        let peak = reduceMotion ? 0.45 : 0.9
        return ZStack {
            Theme.surface
            if let camera {
                CameraPreview(session: camera.session, position: position, running: phase == .running)
                    .opacity(phase == .running ? 1 : 0)
                    .blur(radius: flipping ? 18 : 0)
                    .scaleEffect(flipping && !reduceMotion ? 0.97 : 1)
                    .animation(Theme.smooth, value: phase)
                    .animation(Theme.smooth, value: flipping)
            }
            // The shutter flash.
            Color.white
                .keyframeAnimator(initialValue: 0.0, trigger: flashes) { flash, value in
                    flash.opacity(value)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        LinearKeyframe(peak, duration: 0.03)
                        CubicKeyframe(0, duration: 0.32)
                    }
                }
                .allowsHitTesting(false)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .top) {
            if let recordingSince {
                TimelineView(.periodic(from: recordingSince, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(recordingSince)))
                    HStack(spacing: 6) {
                        Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.background.opacity(0.7)))
                }
                .padding(.top, 12)
                .transition(.opacity)
                .accessibilityIdentifier("camera.recording")
            }
        }
        .animation(Theme.snappy, value: recordingSince)
        .accessibilityHidden(true)
        .toast($toast)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack {
            lastShot
                .frame(width: 64, height: 64)
            Spacer()
            Group {
                if mode == .photo {
                    Button(action: shoot) { EmptyView() }
                        .buttonStyle(ShutterStyle(busy: capturing))
                        .accessibilityLabel("Take photo")
                } else {
                    Button(action: toggleRecording) { EmptyView() }
                        .buttonStyle(RecordStyle(recording: recordingSince != nil, busy: settling))
                        .accessibilityLabel(recordingSince == nil ? "Record video" : "Stop recording")
                }
            }
            .disabled(phase != .running || settling)
            .accessibilityIdentifier("camera.shutter")
            Spacer()
            Button(action: flip) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(Double(flipTurns) * 180))
            }
            .buttonStyle(CircleButtonStyle(size: 56, fill: Theme.surface))
            .disabled(phase != .running || flipping || recordingSince != nil)
            .opacity(canFlip ? 1 : 0)
            .allowsHitTesting(canFlip)
            .accessibilityHidden(!canFlip)
            .accessibilityLabel(position == .back ? "Use front camera" : "Use back camera")
            .accessibilityIdentifier("camera.flip")
            .frame(width: 64, height: 64)
        }
        .padding(.horizontal, 28)
    }

    /// Photo or video, like the iPhone's camera. Locked while recording.
    private var modePicker: some View {
        HStack(spacing: 28) {
            ForEach([CaptureMode.photo, .video], id: \.self) { option in
                Button {
                    setMode(option)
                } label: {
                    Text(option == .photo ? "Photo" : "Video")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(mode == option ? Theme.primary : Theme.tertiary)
                        .frame(minWidth: 64, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
                .accessibilityIdentifier(option == .photo ? "camera.mode.photo" : "camera.mode.video")
            }
        }
        .disabled(phase != .running || recordingSince != nil || settling)
        .opacity(recordingSince == nil ? 1 : 0.3)
        .animation(Theme.snappy, value: mode)
    }

    /// The newest shot of this visit, with how many were taken.
    private var lastShot: some View {
        ZStack(alignment: .topTrailing) {
            if let last = shots.last {
                Button { open(last) } label: {
                    Group {
                        if let image = last.image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            GlyphView(glyph: .photos).padding(14).foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.primary.opacity(0.85), lineWidth: 1.5))
                }
                .buttonStyle(PressableButtonStyle(scale: 0.92))
                .disabled(recordingSince != nil)
                .matchedTransitionSource(id: "camera.last", in: zoom)
                .id(last.id)
                .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.2).combined(with: .opacity))
                .accessibilityLabel("Last shot")
                .accessibilityIdentifier("camera.last")

                Text("\(shots.count)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .contentTransition(.numericText(value: Double(shots.count)))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Capsule().fill(Theme.primary))
                    .overlay(Capsule().strokeBorder(Theme.background, lineWidth: 2))
                    .offset(x: 7, y: -7)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(counted(shots.count, "shot taken", "shots taken"))
            }
        }
        .frame(width: 64, height: 64, alignment: .center)
    }

    private func unavailable(_ reason: CameraUnavailable) -> some View {
        VStack(spacing: 18) {
            GlyphView(glyph: .camera, lineWidth: 1.5)
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.secondary)
                .frame(width: 96, height: 96)
                .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.surface))
            VStack(spacing: 8) {
                Text(reason.title)
                    .font(.casitaTitle2)
                    .multilineTextAlignment(.center)
                Text(reason.detail)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reason == .noAccess {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(RaisedButtonStyle())
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 36)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera.unavailable")
    }

    // MARK: Actions

    private func start() async {
        let camera = self.camera ?? CameraController()
        self.camera = camera
        if let reason = await camera.start() {
            withAnimation(Theme.smooth) { phase = .unavailable(reason) }
            return
        }
        position = camera.position
        canFlip = CameraController.canFlip
        rotation = CameraController.rotationCoordinator(for: position)
        withAnimation(Theme.smooth) { phase = .running }
    }

    private func shoot() {
        guard let camera, phase == .running, !capturing else { return }
        guard entitlements.allows(.add) else { showPaywall = true; return }
        capturing = true
        flashes += 1
        let angle = rotation?.videoRotationAngleForHorizonLevelCapture
        Task {
            do {
                try await storage.checkCanAddItem(in: space)
                let data = try await camera.capturePhoto(rotationAngle: angle)
                capturing = false
                save(data)
            } catch {
                capturing = false
                failed(error)
                // A stopped or broken session is started again for the next try.
                camera.resume()
            }
        }
    }

    /// Queues the shot behind any save still running.
    private func save(_ data: Data) {
        let name = "Casita \(Self.stamp.string(from: .now)).jpg"
        let previous = saving
        saving = Task {
            await previous?.value
            do {
                let item = try await MediaImport.importData(data, named: name, into: storage, space: space)
                let image = await Thumbnail.display(data: data, maxPixels: 240)
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.bouncy) {
                    shots.append(Shot(item: item, image: image))
                }
                Haptics.play(.success)
                toast = "Saved to this space"
            } catch {
                failed(error)
            }
        }
    }

    private func setMode(_ new: CaptureMode) {
        guard let camera, new != mode, phase == .running, recordingSince == nil, !settling else { return }
        Haptics.play(.select)
        mode = new
        settling = true
        Task {
            await camera.setVideoMode(new == .video)
            settling = false
        }
    }

    private func toggleRecording() {
        guard let camera, phase == .running, !settling else { return }
        if recordingSince == nil {
            guard entitlements.allows(.add) else { showPaywall = true; return }
            let angle = rotation?.videoRotationAngleForHorizonLevelCapture
            Task {
                do {
                    try await storage.checkCanAddItem(in: space)
                    try await camera.startRecording(rotationAngle: angle)
                    Haptics.play(.soft)
                    recordingSince = .now
                } catch {
                    failed(error)
                }
            }
        } else {
            settling = true
            recordingSince = nil
            Haptics.play(.thud)
            Task {
                do {
                    let url = try await camera.stopRecording()
                    saveVideo(url)
                } catch {
                    failed(error)
                }
                settling = false
            }
        }
    }

    /// Streams the clip into the space, then deletes the temporary file.
    private func saveVideo(_ url: URL) {
        let name = "Casita \(Self.stamp.string(from: .now)).mov"
        let previous = saving
        saving = Task {
            await previous?.value
            do {
                let item = try await MediaImport.importFile(at: url, named: name, into: storage, space: space)
                var image: UIImage?
                if let thumb = try? await storage.readFile(named: item.thumbName, in: space) {
                    image = await Thumbnail.display(data: thumb, maxPixels: 240)
                }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.bouncy) {
                    shots.append(Shot(item: item, image: image))
                }
                Haptics.play(.success)
                toast = "Saved to this space"
            } catch {
                MediaTemp.remove(url)
                failed(error)
            }
        }
    }

    private func flip() {
        guard let camera, phase == .running, canFlip, !flipping else { return }
        Haptics.play(.select)
        flipping = true
        withAnimation(reduceMotion ? nil : Theme.smooth) { flipTurns += 1 }
        Task {
            position = await camera.flip()
            rotation = CameraController.rotationCoordinator(for: position)
            flipping = false
        }
    }

    private func open(_ shot: Shot) {
        viewing = shot.item
    }

    /// Drops shots deleted from the viewer.
    private func pruneShots() async {
        guard let names = try? await storage.fileNames(in: space) else { return }
        let kept = Set(names)
        withAnimation(Theme.snappy) { shots.removeAll { !kept.contains($0.item.name) } }
    }

    private func failed(_ error: any Error) {
        if error is PlanLimit { showPaywall = true; return }
        Haptics.play(.error)
        toast = switch error {
        case let error as StorageError: mediaErrorText(error)
        case let error as CameraError where error == .notReady: "The camera isn't ready yet. Try again."
        default: mode == .video ? "Couldn't record that video. Try again." : "Couldn't take that photo. Try again."
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

/// The shutter: a white ring and disc. The disc springs in under the finger
/// and dims while a photo is being taken.
private struct ShutterStyle: ButtonStyle {
    var busy: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().strokeBorder(Theme.primary, lineWidth: 4)
                .frame(width: 80, height: 80)
            Circle().fill(Theme.primary)
                .frame(width: 66, height: 66)
                .scaleEffect(configuration.isPressed ? 0.84 : busy ? 0.92 : 1)
                .opacity(busy ? 0.55 : 1)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Circle())
        .animation(Theme.bouncy, value: configuration.isPressed)
        .animation(Theme.snappy, value: busy)
        .onChange(of: configuration.isPressed) { _, down in if down { Haptics.play(.tap) } }
    }
}

/// The record button: a white ring around a red disc that becomes a
/// rounded square while recording.
private struct RecordStyle: ButtonStyle {
    var recording: Bool
    var busy: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().strokeBorder(Theme.primary, lineWidth: 4)
                .frame(width: 80, height: 80)
            RoundedRectangle(cornerRadius: recording ? 8 : 33, style: .continuous)
                .fill(Theme.danger)
                .frame(width: recording ? 32 : 66, height: recording ? 32 : 66)
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .opacity(busy ? 0.55 : 1)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Circle())
        .animation(Theme.bouncy, value: recording)
        .animation(Theme.bouncy, value: configuration.isPressed)
        .onChange(of: configuration.isPressed) { _, down in if down { Haptics.play(.tap) } }
    }
}

/// Why the camera can't start, in plain words with what to do.
enum CameraUnavailable: Equatable, Sendable {
    case notInBuild, noAccess, noCamera

    var title: String {
        switch self {
        case .notInBuild: "The camera isn't set up in this build"
        case .noAccess: "Casita can't use the camera"
        case .noCamera: "No camera on this device"
        }
    }

    var detail: String {
        switch self {
        case .notInBuild: "Add photos from your library instead."
        case .noAccess: "Allow Camera for Casita under Settings > Apps > Casita, then come back."
        case .noCamera: "You can still add photos and videos from your library."
        }
    }
}

enum CameraError: Error {
    /// The session isn't running or has no camera connected.
    case notReady
    /// The camera finished without a picture.
    case noPhoto
}

// MARK: Capture

/// One capture session. Configuration, start, stop and capture all run on
/// `queue`; the stored state below is only touched there, which is why the
/// type can be `@unchecked Sendable`. Nothing here asks for location, so the
/// JPEG carries none.
final class CameraController: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var audioInput: AVCaptureDeviceInput?
    /// The clip being recorded, if any.
    private var recording: MovieRecording?
    private let queue = DispatchQueue(label: "casita.camera")
    // Queue only.
    private var input: AVCaptureDeviceInput?
    private var configured = false
    /// Each photo on its way keeps its own delegate (and continuation) here
    /// until AVFoundation says it is done, so captures never share state.
    private var inFlight: [Int64: PhotoCapture] = [:]

    /// Which camera is in use. Read once start() or flip() has returned.
    private(set) var position: AVCaptureDevice.Position = .back

    static var canFlip: Bool { device(.back) != nil && device(.front) != nil }

    private static func device(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Follows the phone's rotation so photos come out upright. Main thread:
    /// it updates there.
    @MainActor
    static func rotationCoordinator(for position: AVCaptureDevice.Position) -> AVCaptureDevice.RotationCoordinator? {
        device(position).map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: nil) }
    }

    /// Starts the session. Returns why it can't, or nil. Checks for a camera
    /// before asking permission, so the simulator never shows a prompt.
    func start() async -> CameraUnavailable? {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else { return .notInBuild }
        guard Self.device(.back) != nil || Self.device(.front) != nil else { return .noCamera }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { return .noAccess }
        default: return .noAccess
        }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.configureAndRun()) }
        }
    }

    private func configureAndRun() -> CameraUnavailable? {
        if !configured {
            guard let device = Self.device(.back) ?? Self.device(.front),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return .noCamera }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return .noCamera
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            self.input = input
            position = device.position
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        return nil
    }

    func stop() {
        queue.async {
            // Leaving mid-recording (Casita locks) keeps nothing: the clip
            // never reaches the space, and its temporary file goes.
            self.recording?.discard()
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Video mode adds the movie output and, if allowed, the microphone;
    /// photo mode takes them out again so photos keep the full sensor.
    func setVideoMode(_ video: Bool) async {
        if video, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined,
           Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.configureVideo(video, mic: micAllowed)
                continuation.resume()
            }
        }
    }

    private func configureVideo(_ video: Bool, mic: Bool) {
        guard configured else { return }
        session.beginConfiguration()
        if video {
            session.sessionPreset = .high
            if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            if mic, audioInput == nil, let device = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
        } else {
            if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
            if let audioInput { session.removeInput(audioInput) }
            audioInput = nil
            session.sessionPreset = .photo
        }
        session.commitConfiguration()
    }

    /// Starts a clip in a protected temporary file. No location metadata.
    func startRecording(rotationAngle: CGFloat?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard self.session.isRunning, !self.movieOutput.isRecording,
                      let connection = self.movieOutput.connection(with: .video), connection.isActive,
                      let url = try? MediaTemp.newFile(named: "clip.mov")
                else { return continuation.resume(throwing: CameraError.notReady) }
                if let rotationAngle, connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                self.movieOutput.metadata = []
                let recording = MovieRecording()
                self.recording = recording
                self.movieOutput.startRecording(to: url, recordingDelegate: recording)
                continuation.resume()
            }
        }
    }

    /// Ends the clip and returns its file once it is complete.
    func stopRecording() async throws -> URL {
        let recording: MovieRecording? = await withCheckedContinuation { continuation in
            queue.async {
                let current = self.recording
                self.recording = nil
                if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
                continuation.resume(returning: current)
            }
        }
        guard let recording else { throw CameraError.notReady }
        return try await recording.result()
    }

    /// Runs the session again after stop(); does nothing before start().
    func resume() {
        queue.async { if self.configured, !self.session.isRunning { self.session.startRunning() } }
    }

    /// Switches between the back and front cameras. Returns the one in use.
    func flip() async -> AVCaptureDevice.Position {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.switchCamera()) }
        }
    }

    private func switchCamera() -> AVCaptureDevice.Position {
        guard let current = input else { return position }
        let next: AVCaptureDevice.Position = current.device.position == .front ? .back : .front
        guard let device = Self.device(next), let newInput = try? AVCaptureDeviceInput(device: device) else { return position }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            input = newInput
            position = next
        } else {
            session.addInput(current)
        }
        session.commitConfiguration()
        return position
    }

    /// Takes one JPEG. Safe to call while another capture is pending: each
    /// gets its own delegate, and each caller is resumed exactly once.
    func capturePhoto(rotationAngle: CGFloat?) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.beginCapture(rotationAngle: rotationAngle, continuation) }
        }
    }

    private func beginCapture(rotationAngle: CGFloat?, _ continuation: CheckedContinuation<Data, any Error>) {
        // capturePhoto raises an Objective-C exception without an active
        // video connection, so check first.
        guard session.isRunning,
              let connection = output.connection(with: .video), connection.isEnabled, connection.isActive,
              output.availablePhotoCodecTypes.contains(.jpeg)
        else {
            continuation.resume(throwing: CameraError.notReady)
            return
        }
        if let rotationAngle, connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        let id = settings.uniqueID
        let capture = PhotoCapture(continuation) { [weak self] in
            guard let self else { return }
            self.queue.async { self.inFlight[id] = nil }
        }
        inFlight[id] = capture
        output.capturePhoto(with: settings, delegate: capture)
    }
}

/// One photo on its way. Resumes its caller exactly once, whichever
/// delegate call comes first, then tells the controller to let it go.
private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let continuation: Mutex<CheckedContinuation<Data, any Error>?>
    private let release: @Sendable () -> Void

    init(_ continuation: CheckedContinuation<Data, any Error>, release: @escaping @Sendable () -> Void) {
        self.continuation = Mutex(continuation)
        self.release = release
    }

    private func finish(_ result: Result<Data, any Error>) {
        let pending = continuation.withLock { value in
            let taken = value
            value = nil
            return taken
        }
        pending?.resume(with: result)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            finish(.success(data))
        } else {
            finish(.failure(CameraError.noPhoto))
        }
    }

    /// Always the last call for a capture. If no photo arrived, the caller
    /// still hears back.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        finish(.failure(error ?? CameraError.noPhoto))
        release()
    }
}

/// One clip on its way to disk. `result()` returns the finished file, or
/// throws; a discarded clip deletes its file instead.
private final class MovieRecording: NSObject, AVCaptureFileOutputRecordingDelegate, Sendable {
    private struct State {
        var outcome: Result<URL, any Error>?
        var waiting: CheckedContinuation<URL, any Error>?
        var discarded = false
    }
    private let state = Mutex(State())

    func discard() {
        let url: URL? = state.withLock { state in
            state.discarded = true
            if case .success(let url)? = state.outcome { return url }
            return nil
        }
        if let url { MediaTemp.remove(url) }
    }

    func result() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<URL, any Error>? in
                if let outcome = state.outcome { return outcome }
                state.waiting = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        // A clip cut short by a full disk or an interruption is still
        // playable when AVFoundation says it finished.
        let usable = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let outcome: Result<URL, any Error> = usable ? .success(url) : .failure(error ?? CameraError.notReady)
        let (waiting, discarded) = state.withLock { state in
            state.outcome = outcome
            let waiting = state.waiting
            state.waiting = nil
            return (waiting, state.discarded)
        }
        if discarded || !usable { MediaTemp.remove(url) }
        if discarded {
            waiting?.resume(throwing: CameraError.notReady)
        } else {
            waiting?.resume(with: outcome)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var position: AVCaptureDevice.Position
    /// Passed so the view hears when the session starts and its preview
    /// connection exists.
    var running: Bool

    /// Keeps the picture upright on whatever screen shows it. A phone held
    /// upright never changes it; the open iPhone Duo's inner screen, which
    /// turns with the phone and starts out wider than tall, does.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private var rotation: AVCaptureDevice.RotationCoordinator?
        private var position: AVCaptureDevice.Position?

        func follow(_ position: AVCaptureDevice.Position) {
            if position != self.position {
                self.position = position
                rotation = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
                    .map { AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: previewLayer) }
            }
            level()
        }

        // Read on layout, not observed. The preview's angle only
        // changes when the screen turns or changes, and both lay this view out.
        override func layoutSubviews() {
            super.layoutSubviews()
            level()
        }

        private func level() {
            guard let angle = rotation?.videoRotationAngleForHorizonLevelPreview,
                  let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .clear
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.follow(position)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.follow(position)
    }
}
