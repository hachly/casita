import RealityKit
import SwiftUI

/// The story a house scene acts out.
enum HouseStory {
    /// Both codes in turn: the front door, then the hidden one.
    case twoCodes
    /// The everyday code opens the front door; everyday photos come out.
    case everyday
    /// The private code finds a door nobody could see; a gold lock comes out.
    case `private`
    /// Filling the everyday space: the front door opens, three photos fly
    /// in one by one, then a login card, and the door shuts.
    case fill

    /// Seconds in one pass.
    var period: Double {
        switch self {
        case .twoCodes: 9.4
        case .everyday, .private: 5.6
        case .fill: 5.4
        }
    }

    /// The frame shown with Reduce Motion: the moment that tells the story.
    var still: Double {
        switch self {
        case .twoCodes: 9.4
        case .everyday: 3.4
        case .private: 3.4
        // Mid-flight: a photo at the door, the login on its way.
        case .fill: 2.6
        }
    }

    /// Haptics on the scene's own moments: a tap per typed digit, a soft
    /// beat as a door opens, a heavier one as it shuts.
    var beats: [Beat] {
        func typing(from start: Double, unlock: Haptics.Kind) -> [Beat] {
            (0..<6).map { Beat(start + Double($0) * 0.16, .tap) } + [Beat(start + 1.05, unlock)]
        }
        switch self {
        case .twoCodes:
            return typing(from: 1.0, unlock: .soft) + [Beat(4.75, .thud)]
                + typing(from: 5.2, unlock: .unlock) + [Beat(8.95, .thud)]
        case .everyday:
            return typing(from: 0.4, unlock: .soft) + [Beat(4.95, .thud)]
        case .private:
            return typing(from: 0.4, unlock: .unlock) + [Beat(4.95, .thud)]
        case .fill:
            // A soft beat as the door opens, a tap as each thing goes in, a thud as it shuts.
            return [Beat(0.35, .soft)] + (0..<3).map { Beat(Script.fillStart(photo: $0) + 1.0, .tap) }
                + [Beat(Script.loginStart + 1.0, .tap), Beat(4.35, .thud)]
        }
    }
}

/// Casita's house in 3D, flat-shaded white on black, posed from a clock:
/// a code is typed above it and a door opens. The front door is for
/// everyday things; a second door on the side is the same white as the
/// wall, so shut it can't be seen at all. Gold only marks the private room.
struct HouseScene: View {
    var story: HouseStory
    var active = true

    var body: some View {
        LoopClock(period: story.period, active: active, rest: 0, still: story.still,
                  beats: story.beats, once: story == .twoCodes) { t in
            HouseView(story: story, t: t)
        }
        .accessibilityHidden(true)
    }
}

private struct HouseView: View {
    var story: HouseStory
    var t: Double

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(HouseModel.make())
        } update: { content in
            guard let root = content.entities.first(where: { $0.name == HouseModel.rootName }) else { return }
            HouseModel.pose(root, story: story, t: t)
        }
        .background(Theme.background)
    }
}

// MARK: Model

@MainActor
private enum HouseModel {
    static let rootName = "casita.house.scene"

    // House size, in metres of scene space.
    static let width: Float = 1.0
    static let height: Float = 0.72
    static let depth: Float = 0.8
    static let doorSize = SIMD2<Float>(0.24, 0.4)

    static func lit(_ white: CGFloat) -> SimpleMaterial {
        var material = SimpleMaterial(color: UIColor(white: white, alpha: 1), roughness: 1, isMetallic: false)
        material.faceCulling = .none
        return material
    }

    static func flat(_ color: UIColor) -> UnlitMaterial {
        UnlitMaterial(color: color)
    }

    static let gold = UIColor(red: 0.914, green: 0.725, blue: 0.286, alpha: 1)

    static func box(_ size: SIMD3<Float>, _ material: any RealityKit.Material, at position: SIMD3<Float> = .zero, name: String = "") -> ModelEntity {
        let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
        entity.position = position
        entity.name = name
        return entity
    }

    static func make() -> Entity {
        let root = Entity()
        root.name = rootName

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 30
        camera.look(at: [0.06, 0.64, 0], from: [0.1, 1.15, 3.9], relativeTo: nil)
        root.addChild(camera)

        let light = DirectionalLight()
        light.light.intensity = 2600
        light.look(at: .zero, from: [-1.2, 2.2, 1.8], relativeTo: nil)
        root.addChild(light)

        // Everything that turns and grows together.
        let house = Entity()
        house.name = "house"
        root.addChild(house)

        house.addChild(box([1.5, 0.004, 1.2], flat(UIColor(white: 0.07, alpha: 1)), at: [0, -0.002, 0]))
        house.addChild(box([width, height, depth], lit(0.93), at: [0, height / 2, 0]))
        let roof = ModelEntity(mesh: roofMesh(), materials: [lit(0.97)])
        roof.position = [0, height, 0]
        house.addChild(roof)
        // A chimney, so the shape reads as a house from any angle.
        house.addChild(box([0.11, 0.2, 0.11], lit(0.93), at: [0.27, height + 0.27, -0.14]))

        // Front door, everyday: dark, on the front wall left of centre.
        house.addChild(door(name: "front", panel: lit(0.2), at: [-0.2, doorSize.y / 2, depth / 2], facing: 0))
        // A window beside it.
        house.addChild(box([0.2, 0.17, 0.006], flat(UIColor(white: 0.1, alpha: 1)), at: [0.2, 0.43, depth / 2 + 0.003]))

        // Hidden door, private: on the right wall, the same white as it.
        let hidden = door(name: "hidden", panel: lit(0.93), at: [width / 2, doorSize.y / 2, 0.05], facing: .pi / 2)
        hidden.addChild(outline())
        house.addChild(hidden)

        // What comes out of each door, and what goes in when filling.
        for i in 0..<3 { house.addChild(photo(i)) }
        house.addChild(lock())
        house.addChild(login())

        // The code being typed, above the roof.
        root.addChild(codeDots())
        return root
    }

    /// A door hinged on its left edge. `facing` turns it onto a side wall.
    /// Children: "<name>.hinge" (the swinging panel) and the dark doorway
    /// behind it.
    static func door(name: String, panel: SimpleMaterial, at position: SIMD3<Float>, facing: Float) -> Entity {
        let frame = Entity()
        frame.name = name
        frame.position = position
        frame.orientation = simd_quatf(angle: facing, axis: [0, 1, 0])
        frame.addChild(box([doorSize.x, doorSize.y, 0.004], flat(UIColor(white: 0.02, alpha: 1)), at: [0, 0, 0.002]))
        let hinge = Entity()
        hinge.name = "\(name).hinge"
        hinge.position = [-doorSize.x / 2, 0, 0.008]
        hinge.addChild(box([doorSize.x, doorSize.y, 0.012], panel, at: [doorSize.x / 2, 0, 0]))
        frame.addChild(hinge)
        return frame
    }

    /// The gold line that finds the hidden door.
    static func outline() -> Entity {
        let line = Entity()
        line.name = "hidden.outline"
        let w = doorSize.x, h = doorSize.y, bar: Float = 0.012
        let gold = flat(gold)
        line.addChild(box([w + bar, bar, 0.004], gold, at: [0, h / 2, 0.016]))
        line.addChild(box([bar, h, 0.004], gold, at: [-w / 2, 0, 0.016]))
        line.addChild(box([bar, h, 0.004], gold, at: [w / 2, 0, 0.016]))
        return line
    }

    static let photoColors: [(UIColor, UIColor)] = [
        (UIColor(red: 0.42, green: 0.62, blue: 0.86, alpha: 1), UIColor(red: 0.36, green: 0.66, blue: 0.42, alpha: 1)),
        (UIColor(red: 0.95, green: 0.62, blue: 0.4, alpha: 1), UIColor(red: 0.98, green: 0.84, blue: 0.5, alpha: 1)),
        (UIColor(red: 0.64, green: 0.52, blue: 0.84, alpha: 1), UIColor(red: 0.92, green: 0.92, blue: 0.95, alpha: 1)),
    ]

    /// An everyday photo: a white card with a sky and a hill.
    static func photo(_ index: Int) -> Entity {
        let card = Entity()
        card.name = "photo.\(index)"
        card.addChild(box([0.22, 0.17, 0.008], flat(.white)))
        let (sky, hill) = photoColors[index]
        card.addChild(box([0.19, 0.14, 0.002], flat(sky), at: [0, 0, 0.005]))
        card.addChild(box([0.19, 0.05, 0.002], flat(hill), at: [0, -0.045, 0.0065]))
        card.scale = .zero
        return card
    }

    /// A gold padlock: body and shackle.
    static func lock() -> Entity {
        let lock = Entity()
        lock.name = "lock"
        let gold = flat(gold)
        lock.addChild(box([0.16, 0.13, 0.05], gold))
        lock.addChild(box([0.03, 0.022, 0.06], flat(UIColor(white: 0.05, alpha: 1)), at: [0, 0, 0]))
        lock.addChild(box([0.024, 0.08, 0.024], gold, at: [-0.05, 0.1, 0]))
        lock.addChild(box([0.024, 0.08, 0.024], gold, at: [0.05, 0.1, 0]))
        lock.addChild(box([0.124, 0.024, 0.024], gold, at: [0, 0.14, 0]))
        lock.scale = .zero
        return lock
    }

    /// A login card: an avatar, two fields and a gold button.
    static func login() -> Entity {
        let card = Entity()
        card.name = "login"
        card.addChild(box([0.24, 0.22, 0.008], flat(.white)))
        let dark = flat(UIColor(white: 0.16, alpha: 1)), field = flat(UIColor(white: 0.86, alpha: 1))
        card.addChild(box([0.05, 0.05, 0.002], dark, at: [0, 0.06, 0.005]))
        card.addChild(box([0.18, 0.026, 0.002], field, at: [0, 0.0, 0.005]))
        card.addChild(box([0.18, 0.026, 0.002], field, at: [0, -0.04, 0.005]))
        card.addChild(box([0.18, 0.03, 0.002], flat(gold), at: [0, -0.082, 0.005]))
        card.scale = .zero
        return card
    }

    /// Six dots: grey when empty, white for the everyday code, gold for the
    /// private one.
    static func codeDots() -> Entity {
        let row = Entity()
        row.name = "dots"
        row.position = [0.08, 1.36, 0.2]
        for i in 0..<6 {
            let dot = Entity()
            dot.position = [(Float(i) - 2.5) * 0.085, 0, 0]
            dot.addChild(ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [flat(UIColor(white: 0.28, alpha: 1))]))
            let white = ModelEntity(mesh: .generateSphere(radius: 0.028), materials: [flat(.white)])
            white.name = "dot.\(i).white"
            white.scale = .zero
            let goldDot = ModelEntity(mesh: .generateSphere(radius: 0.028), materials: [flat(gold)])
            goldDot.name = "dot.\(i).gold"
            goldDot.scale = .zero
            dot.addChild(white)
            dot.addChild(goldDot)
            row.addChild(dot)
        }
        return row
    }

    /// A triangular prism, ridge front to back, with a normal per face so
    /// each face shades as one flat tone.
    static func roofMesh() -> MeshResource {
        let w = width / 2 + 0.07, h: Float = 0.4, d = depth / 2 + 0.05
        let a = SIMD3<Float>(-w, 0, d), b = SIMD3<Float>(w, 0, d), c = SIMD3<Float>(0, h, d)
        let a2 = SIMD3<Float>(-w, 0, -d), b2 = SIMD3<Float>(w, 0, -d), c2 = SIMD3<Float>(0, h, -d)
        let left = simd_normalize(SIMD3<Float>(-h, w, 0)), right = simd_normalize(SIMD3<Float>(h, w, 0))
        let faces: [([SIMD3<Float>], SIMD3<Float>)] = [
            ([a, b, c], [0, 0, 1]),
            ([b2, a2, c2], [0, 0, -1]),
            ([a, c, c2, a2], left),
            ([b, b2, c2, c], right),
            ([a, a2, b2, b], [0, -1, 0]),
        ]
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        for (points, normal) in faces {
            let base = UInt32(positions.count)
            positions += points
            normals += Array(repeating: normal, count: points.count)
            indices += points.count == 3 ? [base, base + 1, base + 2] : [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        var descriptor = MeshDescriptor(name: "roof")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: 0.01)
    }

    // MARK: Posing

    /// Places everything for moment `t` of `story`.
    static func pose(_ root: Entity, story: HouseStory, t: Double) {
        guard let house = root.findEntity(named: "house") else { return }
        let grow = Ease.settle(Ease.progress(t, 0, 0.9))
        house.scale = SIMD3(repeating: Float(max(0.001, grow)))
        // Turned so the right wall shows, with a slow sway.
        let turn = -0.42 + 0.06 * sin(t * 0.7) + (1 - grow) * -0.5
        house.orientation = simd_quatf(angle: Float(turn), axis: [0, 1, 0])

        let script = Script(story: story)
        // No code is typed while filling, so no dots.
        root.findEntity(named: "dots")?.isEnabled = story != .fill
        for i in 0..<6 {
            root.findEntity(named: "dot.\(i).white")?.scale = SIMD3(repeating: Float(script.dot(i, t: t, gold: false)))
            root.findEntity(named: "dot.\(i).gold")?.scale = SIMD3(repeating: Float(script.dot(i, t: t, gold: true)))
        }

        let front = script.front(t)
        // Negative swings out, towards the camera.
        root.findEntity(named: "front.hinge")?.orientation = simd_quatf(angle: Float(-front * 1.7), axis: [0, 1, 0])
        let hidden = script.hidden(t)
        // Shut, the hidden door isn't drawn at all, so the wall is whole.
        root.findEntity(named: "hidden")?.isEnabled = hidden.outline > 0.01
        root.findEntity(named: "hidden.hinge")?.orientation = simd_quatf(angle: Float(-hidden.open * 1.7), axis: [0, 1, 0])
        root.findEntity(named: "hidden.outline")?.scale = SIMD3(repeating: Float(max(0.001, hidden.outline)))

        let doorway = SIMD3<Float>(-0.2, 0.2, depth / 2)
        let fanned: [SIMD3<Float>] = [[-0.62, 0.5, 0.75], [-0.3, 0.72, 0.85], [0.02, 0.48, 0.95]]
        for i in 0..<3 {
            guard let card = root.findEntity(named: "photo.\(i)") else { continue }
            let (p, size) = script.photoPose(i, t: t)
            card.position = doorway + (fanned[i] - doorway) * Float(p)
            card.scale = SIMD3(repeating: Float(max(0.001, size)))
            card.orientation = simd_quatf(angle: Float((Double(i) - 1) * 0.16 * p) + 0.42, axis: [0, 1, 0])
        }

        if let login = root.findEntity(named: "login") {
            let (p, size) = script.login(t)
            let start = SIMD3<Float>(0.42, 0.86, 1.0)
            login.position = doorway + (start - doorway) * Float(p)
            login.scale = SIMD3(repeating: Float(max(0.001, size)))
            login.orientation = simd_quatf(angle: Float(0.42 - 0.12 * p), axis: [0, 1, 0])
        }

        if let lock = root.findEntity(named: "lock") {
            let p = script.lock(t)
            let start = SIMD3<Float>(width / 2, 0.22, 0.05), end = SIMD3<Float>(0.86, 0.5, 0.3)
            lock.position = start + (end - start) * Float(p)
            lock.scale = SIMD3(repeating: Float(max(0.001, min(1, p * 1.2))))
            lock.orientation = simd_quatf(angle: Float(0.42 - 0.3 * p), axis: [0, 1, 0])
        }
    }
}

/// When each part moves, per story. Every value is 0 (shut, hidden) to 1
/// (open, out).
private struct Script {
    var story: HouseStory

    /// Start of the everyday typing, and of the private typing.
    private var everydayAt: Double? {
        switch story {
        case .twoCodes: 1.0
        case .everyday: 0.4
        case .private, .fill: nil
        }
    }

    private var privateAt: Double? {
        switch story {
        case .twoCodes: 5.2
        case .private: 0.4
        case .everyday, .fill: nil
        }
    }

    /// When each photo appears in front of the house, and the login card.
    static func fillStart(photo i: Int) -> Double { 0.6 + Double(i) * 0.3 }
    static let loginStart = 2.15

    /// Everything a code opened goes back this long after it was typed.
    private let holdOpen = 3.0

    func dot(_ i: Int, t: Double, gold: Bool) -> Double {
        guard let start = gold ? privateAt : everydayAt else { return 0 }
        let typed = Ease.back(Ease.progress(t, start + Double(i) * 0.16, start + Double(i) * 0.16 + 0.18))
        let cleared = Ease.progress(t, start + holdOpen + 0.7, start + holdOpen + 0.9)
        return max(0, typed * (1 - cleared))
    }

    func front(_ t: Double) -> Double {
        if story == .fill { return Ease.window(t, 0.3, 3.95, rise: 0.55, fall: 0.4) }
        guard let start = everydayAt else { return 0 }
        return Ease.window(t, start + 1.05, start + holdOpen + 0.75, rise: 0.55, fall: 0.4)
    }

    func hidden(_ t: Double) -> (outline: Double, open: Double) {
        guard let start = privateAt else { return (0, 0) }
        let outline = Ease.window(t, start + 0.95, start + holdOpen + 0.95, rise: 0.25, fall: 0.3)
        let open = Ease.window(t, start + 1.25, start + holdOpen + 0.75, rise: 0.55, fall: 0.4)
        return (outline, open)
    }

    func photo(_ i: Int, t: Double) -> Double {
        guard let start = everydayAt else { return 0 }
        let out = start + 1.3 + Double(i) * 0.12
        return Ease.settle(Ease.progress(t, out, out + 0.7)) * (1 - Ease.inOut(Ease.progress(t, start + holdOpen, start + holdOpen + 0.45)))
    }

    /// Out (1, in front of the house) to in (0, at the door), and size.
    /// Filling, each pops up out front and flies in, shrinking through the
    /// door; otherwise the everyday photos come out.
    func photoPose(_ i: Int, t: Double) -> (Double, Double) {
        guard story == .fill else {
            let p = photo(i, t: t)
            return (p, min(1, p * 1.2))
        }
        return flyIn(from: Self.fillStart(photo: i), t: t)
    }

    func login(_ t: Double) -> (Double, Double) {
        story == .fill ? flyIn(from: Self.loginStart, t: t) : (0, 0)
    }

    private func flyIn(from start: Double, t: Double) -> (Double, Double) {
        let appear = Ease.settle(Ease.progress(t, start, start + 0.3))
        let travel = Ease.inOut(Ease.progress(t, start + 0.35, start + 1.05))
        guard travel < 1 else { return (0, 0) }
        return (1 - travel, appear * (1 - travel * 0.8))
    }

    func lock(_ t: Double) -> Double {
        guard let start = privateAt else { return 0 }
        let out = start + 1.55
        return Ease.settle(Ease.progress(t, out, out + 0.75)) * (1 - Ease.inOut(Ease.progress(t, start + holdOpen, start + holdOpen + 0.45)))
    }
}
