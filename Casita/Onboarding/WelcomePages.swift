import SwiftUI

/// Step 1. The logo plays its entrance large in the middle, then rises as
/// the wordmark and the first headline arrive. Three pages follow, each with
/// an illustration that acts out its idea. Swipe or Continue moves on; a
/// story bar at the top shows where you are.
struct WelcomePages: View {
    var onDone: () -> Void
    /// "Restore from a backup", offered on the first and last pages.
    var onRestore: () -> Void = {}

    struct Page {
        var lead: String?
        var title: String
        var line: String?
    }

    static let pages: [Page] = [
        Page(title: "Reclaim your privacy.", line: "Keep your photos, files and accounts private. If someone makes you open Casita, give a different code."),
        Page(title: "Military-grade security.", line: "We cannot open your spaces."),
        Page(title: "Fully secure.", line: "Each wrong code makes the next wait longer."),
        Page(title: "Fully local.", line: "No account. No tracking. Encrypted backups go only to your iCloud."),
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingCompact) private var compact
    @State private var page: Int?
    @State private var introDone: Bool

    /// `startAtEnd` (coming back from the code step) skips the logo and
    /// opens on the last page.
    init(onDone: @escaping () -> Void, onRestore: @escaping () -> Void = {}, startAtEnd: Bool = false) {
        self.onDone = onDone
        self.onRestore = onRestore
        _page = State(initialValue: startAtEnd ? Self.pages.count - 1 : 0)
        _introDone = State(initialValue: startAtEnd)
    }

    private var current: Int { page ?? 0 }
    /// Someone with a backup finds it at once, or after reading through.
    private var showsRestore: Bool { introDone && (current == 0 || current == last) }
    private var last: Int { Self.pages.count - 1 }

    var body: some View {
        WideReader { split in
            VStack(spacing: 0) {
                StoryBar(count: Self.pages.count, current: current)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 10)
                    .opacity(introDone ? 1 : 0)
                    .animation(Theme.smooth.delay(0.45), value: introDone)
                pager(split: split)
                    // A wide screen keeps the buttons under the words, on
                    // the trailing half.
                    .overlay(alignment: .bottom) {
                        if let split { actions.padding(.leading, split) }
                    }
                if split == nil { actions }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.welcome")
        .onChange(of: page) { old, new in
            if introDone, let new, new != old { Haptics.play(.select) }
        }
        .onChange(of: page, initial: true) { _, new in
            SetupFunnel.Step(rawValue: SetupFunnel.Step.welcome1.rawValue + (new ?? 0)).map { SetupFunnel.reached($0) }
        }
    }

    private func pager(split: CGFloat?) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Self.pages.indices, id: \.self) { i in
                        pageView(i, size: geometry.size, split: split)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
            .scrollDisabled(!introDone)
            // A scroll view draws into the safe area. With a bar down the
            // side (a closed iPhone Duo) that showed a strip of the next page.
            .clipped()
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Button(action: advance) {
                Text(current == last ? "Set up Casita" : "Continue").contentTransition(.opacity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("onboarding.next")
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 4)
            // Always laid out, shown on the last page, so nothing jumps.
            Button("Restore from a backup", action: onRestore)
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("onboarding.restore")
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 6)
                .opacity(showsRestore ? 1 : 0)
                .allowsHitTesting(showsRestore)
                .accessibilityHidden(!showsRestore)
                .animation(Theme.snappy, value: showsRestore)
            .opacity(introDone ? 1 : 0)
            .offset(y: introDone ? 0 : 18)
            .animation(Theme.smooth.delay(0.6), value: introDone)
            .animation(Theme.snappy, value: current == last)
            .allowsHitTesting(introDone)
        }
        .column()
    }

    private func advance() {
        if current < last {
            withAnimation(.smooth(duration: 0.5)) { page = current + 1 }
        } else {
            onDone()
        }
    }

    // MARK: Pages

    /// One page. On a wide screen the illustration (or the logo) takes the
    /// leading half and the words the trailing half, above the buttons.
    private func pageView(_ i: Int, size: CGSize, split: CGFloat?) -> some View {
        let p = Self.pages[i]
        let wide = split != nil
        let textHeight: CGFloat = compact ? 158 : 200
        let isHero = i == 0
        // Parallax as the page moves under the finger; plain fades with Reduce Motion.
        let depth: CGFloat = reduceMotion ? 0 : 1
        let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        return layout {
            Group {
                if isHero { Color.clear } else { scene(i) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, compact && !wide ? 8 : 20)
            .padding(.bottom, 8)
            .frame(width: split)
            .scrollTransition(axis: .horizontal) { content, phase in
                content
                    .offset(x: phase.value * -70 * depth)
                    .scaleEffect(1 - abs(phase.value) * 0.12 * depth)
                    .opacity(1 - abs(phase.value) * 0.7)
            }
            if !isHero || wide {
            VStack(spacing: compact && !wide ? 10 : 14) {
                TwoToneTitle(lead: p.lead, key: p.title, font: compact && !wide ? .casitaTitle : .casitaDisplay, alignment: .center)
                if let line = p.line {
                    Text(line)
                        .font(compact && !wide ? .body : .title3)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: wide ? nil : textHeight, maxHeight: wide ? .infinity : nil, alignment: wide ? .center : .top)
            .padding(.horizontal, Theme.gutter)
            .column()
            // Clear of the buttons, which sit under the words.
            .padding(.bottom, wide ? 130 : 0)
            .opacity(isHero && !introDone ? 0 : 1)
            .offset(y: isHero && !introDone && !reduceMotion ? 16 : 0)
            .animation(Theme.smooth.delay(0.32), value: introDone)
            .scrollTransition(axis: .horizontal) { content, phase in
                content
                    .offset(x: phase.value * 36 * depth)
                    .opacity(1 - abs(phase.value) * 0.9)
            }
            }
        }
        .overlay(alignment: .leading) {
            if isHero {
                hero(in: CGSize(width: split ?? size.width, height: size.height), page: p, words: !wide)
                    .frame(width: split ?? size.width, height: size.height)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.welcome.page.\(i)")
    }

    @ViewBuilder private func scene(_ i: Int) -> some View {
        let active = introDone && current == i
        switch i {
        case 1: ScenePlayer<ShieldScene>(active: active)
        case 2: ScenePlayer<WaitScene>(active: active)
        default: ScenePlayer<LocalScene>(active: active)
        }
    }

    // MARK: Hero

    /// The logo: large and centred for its entrance, then risen to sit above
    /// the wordmark. `words` false leaves the headline to the trailing half
    /// of a wide screen.
    private func hero(in size: CGSize, page: Page, words: Bool = true) -> some View {
        let big = min(size.width * 0.56, 232)
        let small: CGFloat = compact && words ? 112 : 148
        let side = introDone ? small : big
        // Logo, wordmark and tagline sit together a little above the middle.
        let center = introDone
            ? CGPoint(x: size.width / 2, y: words ? size.height * 0.42 - 40 : size.height / 2 - 40)
            : CGPoint(x: size.width / 2, y: size.height / 2 - 12)
        let word = center.y + small / 2 + (compact ? 28 : 36)
        return ZStack {
            ZStack {
                if introDone {
                    LoopClock(period: 7, active: current == 0, still: 0) { t in
                        CasitaMark(pose: Self.idlePose(at: t))
                    }
                    .transition(.identity)
                } else {
                    CasitaMarkIntro(play: true, onFinished: finishIntro)
                        .transition(.identity)
                }
            }
            .frame(width: side, height: side)
            .position(center)
            Text("Casita")
                .font(.system(size: compact ? 30 : 36, weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(Theme.primary)
                .position(x: size.width / 2, y: word)
                .opacity(introDone ? 1 : 0)
                .offset(y: introDone ? 0 : 12)
                .animation(Theme.smooth.delay(0.2), value: introDone)
            // The headline and its sentence hang from a fixed top, so a
            // longer sentence grows down, never up into the wordmark.
            if words {
            VStack(spacing: compact ? 8 : 12) {
                Text(page.title)
                    .font((compact ? Font.body : .title3).weight(.semibold))
                    .foregroundStyle(Theme.primary)
                if let line = page.line {
                    Text(line)
                        .font(compact ? .subheadline : .body)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: min(size.width, Adaptive.column) - Theme.gutter * 2, height: 220, alignment: .top)
            .position(x: size.width / 2, y: word + (compact ? 22 : 28) + 110)
                .opacity(introDone ? 1 : 0)
                .offset(y: introDone ? 0 : 10)
                .animation(Theme.smooth.delay(0.34), value: introDone)
            }
        }
        .allowsHitTesting(false)
    }

    private func finishIntro() {
        guard !introDone else { return }
        if reduceMotion {
            introDone = true
            return
        }
        withAnimation(.spring(duration: 0.85, bounce: 0.2)) { introDone = true }
        Task { await Choreo.play([Beat(0.42, .soft), Beat(0.72, .tap)]) }
    }

    /// The finished logo, with a glance now and then.
    static func idlePose(at t: Double) -> MarkPose {
        var pose = MarkPose.final
        let glance = Ease.progress(t, 4.2, 4.85)
        pose.look = glance <= 0 || glance >= 1 ? 0 : CGFloat(sin(glance * .pi * 2)) * -14
        return pose
    }
}

/// A clock-driven scene sized and run by `ScenePlayer`.
protocol ClockScene: View {
    init(t: Double)
    static var size: CGSize { get }
    static var period: Double { get }
    static var still: Double { get }
    static var beats: [Beat] { get }
}

/// Plays a scene while `active`, scaled to the room it has.
struct ScenePlayer<S: ClockScene>: View {
    var active: Bool
    var hapticLoops = 1

    var body: some View {
        SceneBox(size: S.size) {
            LoopClock(period: S.period, active: active, still: S.still, beats: S.beats, hapticLoops: hapticLoops) { t in
                S(t: t)
            }
        }
    }
}

extension ShieldScene: ClockScene {}
extension WaitScene: ClockScene {}
extension LocalScene: ClockScene {}
