//
//  ContentView.swift
//  Doodle Road
//
//  GAME IDEA
//  A top view paper world. Draw a road with your finger from the car to the flag.
//  Static things (rocks, bushes, ponds, cones, crates) block your pen, wandering sheep
//  cross the road, so time your drive. Collect stars, grab boost pads, save ink.
//  40 levels in 4 paper worlds, stars are saved, stars unlock new cars in the Garage.
//

import SwiftUI
import UIKit
import Combine

// MARK: - Small helpers

func pdist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lenSq = dx * dx + dy * dy
    if lenSq == 0 { return pdist(p, a) }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
    t = max(0, min(1, t))
    return pdist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}

func lerpAngle(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    var d = b - a
    while d > CGFloat.pi { d -= 2 * CGFloat.pi }
    while d < -CGFloat.pi { d += 2 * CGFloat.pi }
    return a + d * t
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// The dark marker colour used for every outline in the game.
    static let ink = Color(hex: 0x2B2D42)
}

extension Font {
    static func doodle(_ size: CGFloat) -> Font {
        Font.custom("MarkerFelt-Wide", size: size)
    }
}

@MainActor
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

// MARK: - Seeded random numbers (so level N is always the same level)

struct SeededRNG {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
        if state == 0 { state = 88172645463325252 }
        for _ in 0..<4 { _ = next() }
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2685821657736338717
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / 9007199254740992.0
    }

    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        a + CGFloat(unit()) * (b - a)
    }

    mutating func int(_ a: Int, _ b: Int) -> Int {
        a + Int(next() % UInt64(b - a + 1))
    }
}

// MARK: - Level model

struct Obstacle: Identifiable {
    let id: Int
    let kind: Int       // 0 rock, 1 bush, 2 pond, 3 cone, 4 crate
    let pos: CGPoint
    let r: CGFloat
}

struct Mover {
    let center: CGPoint
    let amp: CGFloat
    let period: Double
    let phase: Double
    let r: CGFloat

    func position(at t: Double) -> CGPoint {
        let a = 2 * Double.pi * t / period + phase
        return CGPoint(x: center.x + amp * CGFloat(sin(a)), y: center.y)
    }

    func facing(at t: Double) -> CGFloat {
        let a = 2 * Double.pi * t / period + phase
        return cos(a) >= 0 ? 1 : -1
    }

    var left: CGPoint { CGPoint(x: center.x - amp, y: center.y) }
    var right: CGPoint { CGPoint(x: center.x + amp, y: center.y) }
}

struct Level {
    let number: Int
    let theme: Int
    let start: CGPoint
    let finish: CGPoint
    let obstacles: [Obstacle]
    let movers: [Mover]
    let stars: [CGPoint]
    let boosts: [CGPoint]
    let ink: CGFloat
}

/// A hidden guaranteed route. Obstacles are always placed away from it,
/// so every level can be solved.
struct Route {
    let pts: [CGPoint]
    let cum: [CGFloat]

    init(_ pts: [CGPoint]) {
        self.pts = pts
        var c: [CGFloat] = [0]
        for i in 1..<pts.count {
            c.append(c[i - 1] + pdist(pts[i - 1], pts[i]))
        }
        self.cum = c
    }

    var length: CGFloat { cum.last ?? 0 }

    func sample(_ f: CGFloat) -> (point: CGPoint, normal: CGVector) {
        let d = max(0, min(1, f)) * length
        var i = 1
        while i < pts.count - 1 && cum[i] < d { i += 1 }
        let a = pts[i - 1]
        let b = pts[i]
        let seg = max(cum[i] - cum[i - 1], 0.001)
        let t = (d - cum[i - 1]) / seg
        let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        let dx = (b.x - a.x) / seg
        let dy = (b.y - a.y) / seg
        return (p, CGVector(dx: -dy, dy: dx))
    }

    func distance(to p: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count {
            best = min(best, distToSegment(p, pts[i - 1], pts[i]))
        }
        return best
    }
}

enum LevelFactory {
    static let worldW: CGFloat = 400
    static let worldH: CGFloat = 640

    private static func radius(for kind: Int, rng: inout SeededRNG) -> CGFloat {
        switch kind {
        case 0: return rng.range(20, 30)
        case 1: return rng.range(22, 32)
        case 2: return rng.range(26, 38)
        case 3: return rng.range(11, 14)
        default: return rng.range(18, 25)
        }
    }

    static func make(_ n: Int) -> Level {
        var rng = SeededRNG(seed: n * 7919 + 13)
        let start = CGPoint(x: rng.range(110, 290), y: 570)
        let finish = CGPoint(x: rng.range(70, 330), y: 70)

        // 1. A guaranteed route from the car to the flag.
        let wpCount = min(1 + n / 4, 5)
        var pts: [CGPoint] = [start]
        var prevX = start.x
        for i in 1...wpCount {
            let y = start.y - (start.y - finish.y) * CGFloat(i) / CGFloat(wpCount + 1)
            var x = rng.range(60, 340)
            var tries = 0
            while abs(x - prevX) < 70 && tries < 12 {
                x = rng.range(60, 340)
                tries += 1
            }
            pts.append(CGPoint(x: x, y: y))
            prevX = x
        }
        pts.append(finish)
        let route = Route(pts)

        // 2. Three stars, a little off the route.
        var stars: [CGPoint] = []
        let fractions: [CGFloat] = [0.2, 0.5, 0.8]
        for (i, f0) in fractions.enumerated() {
            let f = f0 + rng.range(-0.04, 0.04)
            let s = route.sample(f)
            let side: CGFloat = (i % 2 == 0) ? 1 : -1
            let off = rng.range(32, 50) * side
            var p = CGPoint(x: s.point.x + s.normal.dx * off, y: s.point.y + s.normal.dy * off)
            p.x = max(40, min(worldW - 40, p.x))
            p.y = max(40, min(worldH - 40, p.y))
            stars.append(p)
        }

        // 3. Wandering sheep that cross the road.
        var movers: [Mover] = []
        let moverCount = n < 5 ? 0 : min(1 + (n - 5) / 8, 3)
        for i in 0..<moverCount {
            let f = 0.3 + 0.5 * (CGFloat(i) + 0.5) / CGFloat(moverCount) + rng.range(-0.03, 0.03)
            let s = route.sample(f)
            let cx = max(100, min(300, s.point.x))
            let amp = rng.range(55, 85)
            let period = Double(rng.range(2.4, 3.8))
            let phase = Double(rng.range(0, 6.28))
            movers.append(Mover(center: CGPoint(x: cx, y: s.point.y), amp: amp, period: period, phase: phase, r: 13))
        }

        // 4. Boost pads on the route.
        var boosts: [CGPoint] = []
        let boostCount = n < 3 ? 0 : min(1 + n / 10, 3)
        let boostFractions: [CGFloat] = [0.35, 0.65, 0.9]
        for i in 0..<boostCount {
            boosts.append(route.sample(boostFractions[i]).point)
        }

        // 5. Obstacles, always away from the route, stars and each other.
        var obstacles: [Obstacle] = []
        let target = min(2 + n / 2, 15)
        var attempts = 0
        while obstacles.count < target && attempts < 800 {
            attempts += 1
            let kind = rng.int(0, 4)
            let r = radius(for: kind, rng: &rng)
            let pos: CGPoint
            if rng.unit() < 0.65 {
                let t = rng.range(0.12, 0.88)
                let px = start.x + (finish.x - start.x) * t + rng.range(-80, 80)
                let py = start.y + (finish.y - start.y) * t + rng.range(-30, 30)
                pos = CGPoint(x: px, y: py)
            } else {
                pos = CGPoint(x: rng.range(40, 360), y: rng.range(90, 550))
            }
            let m: CGFloat = r + 14
            if pos.x < m || pos.x > worldW - m { continue }
            if pos.y < m || pos.y > worldH - m { continue }
            if pdist(pos, start) < r + 70 || pdist(pos, finish) < r + 70 { continue }
            if route.distance(to: pos) < r + 38 { continue }
            if stars.contains(where: { pdist($0, pos) < r + 28 }) { continue }
            if movers.contains(where: { distToSegment(pos, $0.left, $0.right) < r + 38 }) { continue }
            if obstacles.contains(where: { pdist($0.pos, pos) < $0.r + r + 44 }) { continue }
            obstacles.append(Obstacle(id: obstacles.count, kind: kind, pos: pos, r: r))
        }

        let factor = CGFloat(max(1.12, 1.5 - Double(n) * 0.01))
        let ink = route.length * factor + 90
        let theme = ((n - 1) / 10) % 4

        return Level(number: n, theme: theme, start: start, finish: finish,
                     obstacles: obstacles, movers: movers, stars: stars,
                     boosts: boosts, ink: ink)
    }
}

// MARK: - Look and feel

struct PaperTheme {
    let paper: Color
    let line: Color

    static let names = ["Notebook", "Mint Graph", "Sunny Sand", "Lilac Dream"]

    static func forIndex(_ i: Int) -> PaperTheme {
        switch i % 4 {
        case 0:
            return PaperTheme(paper: Color(hex: 0xFDF6E3), line: Color(hex: 0x9EC5FE, opacity: 0.55))
        case 1:
            return PaperTheme(paper: Color(hex: 0xEAFAF1), line: Color(hex: 0x8FD5A6, opacity: 0.6))
        case 2:
            return PaperTheme(paper: Color(hex: 0xFFF0D9), line: Color(hex: 0xE0B57A, opacity: 0.6))
        default:
            return PaperTheme(paper: Color(hex: 0xF1EBFF), line: Color(hex: 0xB7A3F0, opacity: 0.55))
        }
    }
}

struct CarSkin: Identifiable {
    let id: Int
    let name: String
    let body: Color
    let accent: Color
    let cost: Int

    static let all: [CarSkin] = [
        CarSkin(id: 0, name: "Scribble", body: Color(hex: 0xEF476F), accent: Color(hex: 0xFFD1DC), cost: 0),
        CarSkin(id: 1, name: "Splash", body: Color(hex: 0x4DABF7), accent: Color(hex: 0xD0EBFF), cost: 6),
        CarSkin(id: 2, name: "Taxi", body: Color(hex: 0xFFD43B), accent: Color(hex: 0x2B2D42), cost: 15),
        CarSkin(id: 3, name: "Leaf", body: Color(hex: 0x51CF66), accent: Color(hex: 0xD3F9D8), cost: 28),
        CarSkin(id: 4, name: "Comet", body: Color(hex: 0x845EF7), accent: Color(hex: 0xE5DBFF), cost: 45),
        CarSkin(id: 5, name: "Midnight", body: Color(hex: 0x343A40), accent: Color(hex: 0xFF6B6B), cost: 65)
    ]
}

struct WorldFit {
    let scale: CGFloat
    let origin: CGPoint

    init(size: CGSize) {
        let s = min(size.width / LevelFactory.worldW, size.height / LevelFactory.worldH)
        scale = s
        origin = CGPoint(x: (size.width - LevelFactory.worldW * s) / 2,
                         y: (size.height - LevelFactory.worldH * s) / 2)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale)
    }
}

// MARK: - Progress and saving

@MainActor
final class GameStore: ObservableObject {
    static let levelCount = 40
    static let perWorld = 10
    private static let starsKey = "doodleRoad.stars.v1"
    private static let skinKey = "doodleRoad.skin.v1"

    @Published private(set) var stars: [Int]
    @Published var selectedSkin: Int {
        didSet { UserDefaults.standard.set(selectedSkin, forKey: Self.skinKey) }
    }

    init() {
        var arr = Array(repeating: 0, count: Self.levelCount)
        let saved = UserDefaults.standard.array(forKey: Self.starsKey) as? [Int] ?? []
        for (i, v) in saved.enumerated() where i < arr.count {
            arr[i] = v
        }
        stars = arr
        selectedSkin = UserDefaults.standard.integer(forKey: Self.skinKey)
    }

    var totalStars: Int { stars.reduce(0, +) }
    var maxStars: Int { Self.levelCount * 3 }

    var currentSkin: CarSkin {
        let i = min(max(selectedSkin, 0), CarSkin.all.count - 1)
        return CarSkin.all[i]
    }

    func isUnlocked(_ n: Int) -> Bool {
        n <= 1 || stars[n - 2] > 0
    }

    func isSkinUnlocked(_ skin: CarSkin) -> Bool {
        totalStars >= skin.cost
    }

    var nextLevel: Int {
        for n in 1...Self.levelCount where stars[n - 1] == 0 {
            return n
        }
        return Self.levelCount
    }

    func record(level n: Int, earned: Int) {
        guard n >= 1, n <= Self.levelCount, earned > stars[n - 1] else { return }
        stars[n - 1] = earned
        UserDefaults.standard.set(stars, forKey: Self.starsKey)
    }
}

// MARK: - Game engine

struct Particle {
    var pos: CGPoint
    var vel: CGVector
    var life: Double
    let maxLife: Double
    let size: CGFloat
    let kind: Int       // 0 smoke, 1 sparkle, 2 crash, 3 boost flame
}

@MainActor
final class GameEngine: ObservableObject {
    enum Phase { case drawing, driving, won, crashed, outOfInk }

    @Published var phase: Phase = .drawing
    @Published var inkLeft: CGFloat
    @Published var collected: Int = 0
    @Published var frame: Int = 0
    @Published var paused: Bool = false

    let level: Level
    private(set) var path: [CGPoint] = []
    private(set) var cumulative: [CGFloat] = []
    private(set) var carPos: CGPoint
    private(set) var carAngle: CGFloat = -CGFloat.pi / 2
    private(set) var starTaken: [Bool]
    private(set) var particles: [Particle] = []
    private(set) var time: Double = 0
    private(set) var boostTimer: Double = 0
    private(set) var shake: CGFloat = 0
    private(set) var blockedFlash: Double = 0
    private(set) var hintFlash: Double = 0
    private(set) var stuckTime: Double = 0

    private var carDistance: CGFloat = 0
    private var touching = false
    private var smokeTimer: Double = 0
    private var lastTick = Date()
    private let baseSpeed: CGFloat = 150
    private let penClear: CGFloat = 15
    private let carRadius: CGFloat = 11

    init(level: Level) {
        self.level = level
        self.inkLeft = level.ink
        self.carPos = level.start
        self.starTaken = Array(repeating: false, count: level.stars.count)
        self.path = [level.start]
        self.cumulative = [0]
    }

    var penEnd: CGPoint { path.last ?? level.start }
    var canGo: Bool { phase == .drawing && path.count > 1 }
    var earnedStars: Int { max(1, collected) }

    // MARK: Controls

    func reset() {
        path = [level.start]
        cumulative = [0]
        carDistance = 0
        carPos = level.start
        carAngle = -CGFloat.pi / 2
        starTaken = Array(repeating: false, count: level.stars.count)
        collected = 0
        inkLeft = level.ink
        boostTimer = 0
        stuckTime = 0
        shake = 0
        particles = []
        touching = false
        paused = false
        phase = .drawing
    }

    func clearRoad() {
        guard phase == .drawing else { return }
        path = [level.start]
        cumulative = [0]
        inkLeft = level.ink
    }

    func go() {
        guard canGo else { return }
        phase = .driving
        Haptics.medium()
    }

    func touchChanged(_ p: CGPoint) {
        guard !paused, phase == .drawing || phase == .driving else { return }
        if !touching {
            if pdist(p, penEnd) <= 52 {
                touching = true
            } else {
                hintFlash = 0.9
                return
            }
        }
        extend(to: p)
    }

    func touchEnded() {
        touching = false
    }

    // MARK: Drawing the road

    private func isFree(_ q: CGPoint) -> Bool {
        if q.x < 14 || q.x > LevelFactory.worldW - 14 { return false }
        if q.y < 14 || q.y > LevelFactory.worldH - 14 { return false }
        for o in level.obstacles where pdist(q, o.pos) < o.r + penClear {
            return false
        }
        return true
    }

    private func extend(to target: CGPoint) {
        var loops = 0
        while loops < 40 {
            loops += 1
            let last = penEnd
            let d = pdist(last, target)
            if d < 6 { return }
            if inkLeft <= 0 {
                inkLeft = 0
                return
            }
            let step = min(d, 6, inkLeft)
            let ux = (target.x - last.x) / d
            let uy = (target.y - last.y) / d
            var moved = false
            for turn in [0.0, 0.6, -0.6, 1.1, -1.1] as [CGFloat] {
                let c = cos(turn)
                let s = sin(turn)
                let dx = ux * c - uy * s
                let dy = ux * s + uy * c
                let q = CGPoint(x: last.x + dx * step, y: last.y + dy * step)
                if isFree(q) {
                    appendPoint(q)
                    moved = true
                    break
                }
            }
            if !moved {
                blockedFlash = 0.35
                return
            }
        }
    }

    private func appendPoint(_ q: CGPoint) {
        let last = path[path.count - 1]
        let seg = pdist(last, q)
        let total = cumulative.last ?? 0
        path.append(q)
        cumulative.append(total + seg)
        inkLeft = max(0, inkLeft - seg)
    }

    // MARK: Game loop

    func step(now: Date) {
        var dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if dt > 0.05 { dt = 0.05 }
        if dt <= 0 || paused { return }

        time += dt
        blockedFlash = max(0, blockedFlash - dt)
        hintFlash = max(0, hintFlash - dt)
        shake = max(0, shake - CGFloat(dt) * 40)
        updateParticles(dt)

        if phase == .driving {
            if boostTimer > 0 { boostTimer = max(0, boostTimer - dt) }
            let speed: CGFloat = baseSpeed * (boostTimer > 0 ? 1.8 : 1.0)
            let total = cumulative.last ?? 0
            if carDistance < total {
                carDistance = min(total, carDistance + speed * CGFloat(dt))
                stuckTime = 0
            } else {
                stuckTime += dt
            }
            updateCar()
            spawnSmoke(dt)
            checkInteractions()
            if phase == .driving && stuckTime > 0.8 && pdist(carPos, level.finish) - 26 > inkLeft {
                phase = .outOfInk
                Haptics.error()
            }
        }
        frame &+= 1
    }

    private func point(at s: CGFloat) -> CGPoint {
        guard path.count > 1, let total = cumulative.last, total > 0 else {
            return path.first ?? level.start
        }
        let d = min(max(s, 0), total)
        var lo = 0
        var hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (d - cumulative[lo]) / segLen : 0
        return CGPoint(x: path[lo].x + (path[hi].x - path[lo].x) * t,
                       y: path[lo].y + (path[hi].y - path[lo].y) * t)
    }

    private func updateCar() {
        carPos = point(at: carDistance)
        let total = cumulative.last ?? 0
        let ahead = point(at: min(total, carDistance + 16))
        let behind = point(at: max(0, carDistance - 6))
        var target = carAngle
        if pdist(ahead, carPos) > 1 {
            target = atan2(ahead.y - carPos.y, ahead.x - carPos.x)
        } else if pdist(carPos, behind) > 1 {
            target = atan2(carPos.y - behind.y, carPos.x - behind.x)
        }
        carAngle = lerpAngle(carAngle, target, 0.22)
    }

    private func spawnSmoke(_ dt: Double) {
        smokeTimer += dt
        let total = cumulative.last ?? 0
        if smokeTimer > 0.045 && carDistance < total {
            smokeTimer = 0
            let back = CGPoint(x: carPos.x - cos(carAngle) * 15, y: carPos.y - sin(carAngle) * 15)
            let boosting = boostTimer > 0
            particles.append(Particle(
                pos: back,
                vel: CGVector(dx: CGFloat.random(in: -8...8), dy: CGFloat.random(in: -8...8)),
                life: 0.5, maxLife: 0.5,
                size: boosting ? 6 : 4,
                kind: boosting ? 3 : 0))
        }
    }

    private func checkInteractions() {
        for i in level.stars.indices where !starTaken[i] {
            if pdist(carPos, level.stars[i]) < 24 {
                starTaken[i] = true
                collected += 1
                burst(at: level.stars[i], kind: 1, count: 12, speed: 90)
                Haptics.tap()
            }
        }
        for b in level.boosts where pdist(carPos, b) < 22 {
            if boostTimer <= 0.2 {
                burst(at: b, kind: 3, count: 8, speed: 80)
                Haptics.tap()
            }
            boostTimer = 1.4
        }
        for m in level.movers {
            if pdist(carPos, m.position(at: time)) < carRadius + m.r - 4 {
                crash()
                return
            }
        }
        if pdist(carPos, level.finish) < 26 {
            win()
        }
    }

    private func crash() {
        phase = .crashed
        shake = 14
        burst(at: carPos, kind: 2, count: 26, speed: 170)
        Haptics.error()
    }

    private func win() {
        phase = .won
        burst(at: level.finish, kind: 1, count: 30, speed: 140)
        Haptics.success()
    }

    private func burst(at p: CGPoint, kind: Int, count: Int, speed: CGFloat) {
        for _ in 0..<count {
            let a = CGFloat.random(in: 0...(2 * CGFloat.pi))
            let v = CGFloat.random(in: (speed * 0.4)...speed)
            particles.append(Particle(
                pos: p,
                vel: CGVector(dx: cos(a) * v, dy: sin(a) * v),
                life: 0.7, maxLife: 0.7,
                size: CGFloat.random(in: 3...6),
                kind: kind))
        }
    }

    private func updateParticles(_ dt: Double) {
        if particles.isEmpty { return }
        for i in particles.indices {
            particles[i].life -= dt
            particles[i].pos.x += particles[i].vel.dx * CGFloat(dt)
            particles[i].pos.y += particles[i].vel.dy * CGFloat(dt)
            particles[i].vel.dx *= 0.96
            particles[i].vel.dy *= 0.96
        }
        particles.removeAll { $0.life <= 0 }
        if particles.count > 250 {
            particles.removeFirst(particles.count - 250)
        }
    }
}

// MARK: - Painter (everything is drawn like a marker doodle)

enum Painter {

    /// Round blobs with one clean outline around the whole group.
    static func blob(_ g: GraphicsContext, circles: [CGRect], fill: Color, outline: Color, width: CGFloat) {
        for rc in circles {
            g.stroke(Path(ellipseIn: rc), with: .color(outline), lineWidth: width * 2)
        }
        for rc in circles {
            g.fill(Path(ellipseIn: rc), with: .color(fill))
        }
    }

    static func smooth(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count == 1 { return p }
        if pts.count == 2 {
            p.addLine(to: pts[1])
            return p
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    static func road(_ g: GraphicsContext, path: Path) {
        g.stroke(path, with: .color(Color.ink),
                 style: StrokeStyle(lineWidth: 31, lineCap: .round, lineJoin: .round))
        g.stroke(path, with: .color(Color(hex: 0x495057)),
                 style: StrokeStyle(lineWidth: 25, lineCap: .round, lineJoin: .round))
        g.stroke(path, with: .color(Color(hex: 0xFFF3BF)),
                 style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, lineJoin: .round, dash: [8, 9]))
    }

    static func obstacle(_ g: GraphicsContext, _ o: Obstacle) {
        let c = o.pos
        let r = o.r
        switch o.kind {
        case 0:
            let rect = CGRect(x: c.x - r, y: c.y - r * 0.85, width: r * 2, height: r * 1.7)
            g.fill(Path(ellipseIn: rect.offsetBy(dx: 3, dy: 4)), with: .color(Color.black.opacity(0.15)))
            g.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0xB8BCC6)))
            let hi = CGRect(x: c.x - r * 0.55, y: c.y - r * 0.55, width: r * 0.7, height: r * 0.4)
            g.fill(Path(ellipseIn: hi), with: .color(Color.white.opacity(0.45)))
            g.stroke(Path(ellipseIn: rect), with: .color(Color.ink), lineWidth: 2.5)
            var crack = Path()
            crack.move(to: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.05))
            crack.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.2))
            crack.addLine(to: CGPoint(x: c.x + r * 0.35, y: c.y))
            g.stroke(crack, with: .color(Color.ink.opacity(0.7)),
                     style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        case 1:
            let spots: [(CGFloat, CGFloat, CGFloat)] = [
                (-0.45, 0.25, 0.62), (0.45, 0.25, 0.62), (0, -0.4, 0.66), (0, 0.15, 0.72)
            ]
            var circles: [CGRect] = []
            for s in spots {
                let rr = r * s.2
                circles.append(CGRect(x: c.x + s.0 * r - rr, y: c.y + s.1 * r - rr, width: rr * 2, height: rr * 2))
            }
            blob(g, circles: circles, fill: Color(hex: 0x7BC67B), outline: Color.ink, width: 2.4)
            g.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                   with: .color(Color(hex: 0x4F9D5B)))
        case 2:
            let rect = CGRect(x: c.x - r, y: c.y - r * 0.85, width: r * 2, height: r * 1.7)
            g.fill(Path(ellipseIn: rect), with: .color(Color(hex: 0x74C0FC)))
            g.stroke(Path(ellipseIn: rect), with: .color(Color(hex: 0x1C7ED6)), lineWidth: 3)
            for dy in [CGFloat(-0.15), CGFloat(0.3)] {
                let y = c.y + dy * r
                var w = Path()
                w.move(to: CGPoint(x: c.x - r * 0.5, y: y))
                w.addQuadCurve(to: CGPoint(x: c.x, y: y), control: CGPoint(x: c.x - r * 0.25, y: y - r * 0.2))
                w.addQuadCurve(to: CGPoint(x: c.x + r * 0.5, y: y), control: CGPoint(x: c.x + r * 0.25, y: y + r * 0.2))
                g.stroke(w, with: .color(Color.white.opacity(0.9)),
                         style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
        case 3:
            let base = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            g.fill(Path(ellipseIn: base.offsetBy(dx: 2, dy: 3)), with: .color(Color.black.opacity(0.15)))
            g.fill(Path(ellipseIn: base), with: .color(Color(hex: 0xFF922B)))
            g.stroke(Path(ellipseIn: base), with: .color(Color.ink), lineWidth: 2.4)
            g.stroke(Path(ellipseIn: base.insetBy(dx: r * 0.35, dy: r * 0.35)), with: .color(Color.white), lineWidth: 2.5)
            g.fill(Path(ellipseIn: base.insetBy(dx: r * 0.65, dy: r * 0.65)), with: .color(Color(hex: 0xE8590C)))
        default:
            let h = r * 0.85
            let box = CGRect(x: c.x - h, y: c.y - h, width: h * 2, height: h * 2)
            g.fill(Path(CGRect(x: box.minX + 3, y: box.minY + 4, width: box.width, height: box.height)),
                   with: .color(Color.black.opacity(0.15)))
            g.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(hex: 0xD9A066)))
            g.stroke(Path(roundedRect: box, cornerRadius: 4), with: .color(Color.ink), lineWidth: 2.5)
            var cross = Path()
            cross.move(to: CGPoint(x: box.minX + 3, y: box.minY + 3))
            cross.addLine(to: CGPoint(x: box.maxX - 3, y: box.maxY - 3))
            cross.move(to: CGPoint(x: box.maxX - 3, y: box.minY + 3))
            cross.addLine(to: CGPoint(x: box.minX + 3, y: box.maxY - 3))
            g.stroke(cross, with: .color(Color.ink.opacity(0.6)), lineWidth: 2)
        }
    }

    static func starPath(center: CGPoint, outer: CGFloat, inner: CGFloat) -> Path {
        var p = Path()
        for i in 0..<10 {
            let rad = (i % 2 == 0) ? outer : inner
            let a = CGFloat.pi / 5 * CGFloat(i) - CGFloat.pi / 2
            let pt = CGPoint(x: center.x + cos(a) * rad, y: center.y + sin(a) * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }

    static func star(_ g: GraphicsContext, at p: CGPoint, time: Double) {
        let s = 1 + 0.08 * CGFloat(sin(time * 5))
        g.fill(Path(ellipseIn: CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)),
               with: .color(Color(hex: 0xFFC933, opacity: 0.25)))
        let sp = starPath(center: p, outer: 13 * s, inner: 5.5 * s)
        g.fill(sp, with: .color(Color(hex: 0xFFC933)))
        g.stroke(sp, with: .color(Color.ink), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
    }

    static func boost(_ g: GraphicsContext, at p: CGPoint, time: Double) {
        let pulse = 1 + 0.06 * CGFloat(sin(time * 6))
        let rr = 19 * pulse
        let disc = Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: rr * 2, height: rr * 2))
        g.fill(disc, with: .color(Color(hex: 0x3BC9DB)))
        g.stroke(disc, with: .color(Color.ink), lineWidth: 2.5)
        let raw: [(CGFloat, CGFloat)] = [(3, -12), (-6, 2), (0, 2), (-3, 12), (7, -3), (1, -3)]
        var bolt = Path()
        for (i, q) in raw.enumerated() {
            let pt = CGPoint(x: p.x + q.0, y: p.y + q.1)
            if i == 0 { bolt.move(to: pt) } else { bolt.addLine(to: pt) }
        }
        bolt.closeSubpath()
        g.fill(bolt, with: .color(Color(hex: 0xFFE066)))
        g.stroke(bolt, with: .color(Color.ink), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
    }

    static func finish(_ g: GraphicsContext, at p: CGPoint, time: Double) {
        let ring = Path(ellipseIn: CGRect(x: p.x - 26, y: p.y - 26, width: 52, height: 52))
        g.fill(ring, with: .color(Color.white.opacity(0.55)))
        g.stroke(ring, with: .color(Color.white), lineWidth: 8)
        g.stroke(ring, with: .color(Color.ink), style: StrokeStyle(lineWidth: 8, dash: [6.5, 6.5]))
        var pole = Path()
        pole.move(to: CGPoint(x: p.x - 4, y: p.y + 8))
        pole.addLine(to: CGPoint(x: p.x - 4, y: p.y - 32))
        g.stroke(pole, with: .color(Color.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        for col in 0..<3 {
            for row in 0..<2 {
                let wave = CGFloat(sin(time * 6 + Double(col) * 0.9)) * 1.5
                let rect = CGRect(x: p.x - 2 + CGFloat(col) * 8,
                                  y: p.y - 32 + CGFloat(row) * 7 + wave,
                                  width: 8, height: 7)
                let dark = (col + row) % 2 == 0
                g.fill(Path(rect), with: .color(dark ? Color.ink : Color.white))
                g.stroke(Path(rect), with: .color(Color.ink), lineWidth: 1)
            }
        }
    }

    static func sheep(_ g: GraphicsContext, at p: CGPoint, r: CGFloat, facing: CGFloat) {
        g.fill(Path(ellipseIn: CGRect(x: p.x - r + 2, y: p.y - r + 4, width: r * 2, height: r * 2)),
               with: .color(Color.black.opacity(0.15)))
        let headC = CGPoint(x: p.x + facing * r * 0.95, y: p.y)
        let headR = r * 0.42
        g.fill(Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR, width: headR * 2, height: headR * 2)),
               with: .color(Color.ink))
        let puffs: [(CGFloat, CGFloat)] = [(-0.5, -0.4), (0.15, -0.55), (0.55, -0.1), (0.3, 0.5), (-0.35, 0.5), (-0.65, 0.05), (0, 0)]
        var circles: [CGRect] = []
        for q in puffs {
            let isCenter = (q.0 == 0 && q.1 == 0)
            let rr = isCenter ? r * 0.7 : r * 0.5
            circles.append(CGRect(x: p.x + q.0 * r - rr, y: p.y + q.1 * r - rr, width: rr * 2, height: rr * 2))
        }
        blob(g, circles: circles, fill: Color.white, outline: Color.ink, width: 2)
    }

    static func car(_ g: GraphicsContext, at p: CGPoint, angle: CGFloat, skin: CarSkin, boosting: Bool) {
        var c = g
        c.translateBy(x: p.x, y: p.y)
        c.rotate(by: Angle.radians(Double(angle)))

        c.fill(Path(roundedRect: CGRect(x: -14, y: -6, width: 30, height: 18), cornerRadius: 7),
               with: .color(Color.black.opacity(0.18)))

        if boosting {
            var flame = Path()
            flame.move(to: CGPoint(x: -14, y: -5))
            flame.addLine(to: CGPoint(x: -28, y: 0))
            flame.addLine(to: CGPoint(x: -14, y: 5))
            flame.closeSubpath()
            c.fill(flame, with: .color(Color(hex: 0xFFA62B)))
            c.stroke(flame, with: .color(Color.ink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }

        let wheels: [CGPoint] = [
            CGPoint(x: -9, y: -10.5), CGPoint(x: -9, y: 10.5),
            CGPoint(x: 9, y: -10.5), CGPoint(x: 9, y: 10.5)
        ]
        for w in wheels {
            let rect = CGRect(x: w.x - 4.5, y: w.y - 2.5, width: 9, height: 5)
            c.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color.ink))
        }

        let body = CGRect(x: -15, y: -9, width: 30, height: 18)
        c.fill(Path(roundedRect: body, cornerRadius: 7), with: .color(skin.body))
        c.stroke(Path(roundedRect: body, cornerRadius: 7), with: .color(Color.ink), lineWidth: 2.2)

        let windshield = CGRect(x: 3, y: -6.5, width: 5, height: 13)
        let roof = CGRect(x: -5, y: -6.5, width: 8, height: 13)
        let rear = CGRect(x: -9, y: -6, width: 4, height: 12)
        c.fill(Path(roundedRect: windshield, cornerRadius: 1.5), with: .color(Color(hex: 0xCFEAFF)))
        c.fill(Path(roundedRect: roof, cornerRadius: 1.5), with: .color(skin.accent))
        c.fill(Path(roundedRect: rear, cornerRadius: 1.5), with: .color(Color(hex: 0xCFEAFF)))
        c.stroke(Path(roundedRect: windshield, cornerRadius: 1.5), with: .color(Color.ink), lineWidth: 1.2)
        c.stroke(Path(roundedRect: roof, cornerRadius: 1.5), with: .color(Color.ink), lineWidth: 1.2)
        c.stroke(Path(roundedRect: rear, cornerRadius: 1.5), with: .color(Color.ink), lineWidth: 1.2)

        c.fill(Path(ellipseIn: CGRect(x: 11, y: -7.5, width: 3.5, height: 3.5)), with: .color(Color(hex: 0xFFE066)))
        c.fill(Path(ellipseIn: CGRect(x: 11, y: 4, width: 3.5, height: 3.5)), with: .color(Color(hex: 0xFFE066)))
    }

    static func particles(_ g: GraphicsContext, _ list: [Particle]) {
        for pt in list {
            let k = CGFloat(max(0, pt.life / pt.maxLife))
            let size: CGFloat = pt.kind == 0 ? pt.size * (1.6 - k * 0.6) : pt.size * (0.4 + k * 0.6)
            let color: Color
            switch pt.kind {
            case 0: color = Color.gray.opacity(0.45 * Double(k))
            case 1: color = Color(hex: 0xFFC933, opacity: Double(k))
            case 2: color = Color(hex: 0xFF6B35, opacity: Double(k))
            default: color = Color(hex: 0xFFA62B, opacity: Double(k))
            }
            let rect = CGRect(x: pt.pos.x - size, y: pt.pos.y - size, width: size * 2, height: size * 2)
            g.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }
}

// MARK: - Reusable UI pieces

struct PaperBackground: View {
    let theme: PaperTheme

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.paper))
            var lines = Path()
            let spacing: CGFloat = 26
            var x: CGFloat = 0
            while x <= size.width {
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            ctx.stroke(lines, with: .color(theme.line), lineWidth: 1)
        }
        .ignoresSafeArea()
    }
}

struct DoodleButtonStyle: ButtonStyle {
    var fill: Color
    var size: CGFloat = 24
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.doodle(size))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color.ink).offset(x: 3, y: 4)
                    RoundedRectangle(cornerRadius: 18).fill(fill)
                    RoundedRectangle(cornerRadius: 18).stroke(Color.ink, lineWidth: 3)
                }
            )
            .opacity(isEnabled ? 1 : 0.45)
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct DoodleIconButtonStyle: ButtonStyle {
    var fill: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .heavy))
            .foregroundStyle(Color.ink)
            .frame(width: 48, height: 48)
            .background(
                ZStack {
                    Circle().fill(Color.ink).offset(x: 2, y: 3)
                    Circle().fill(fill)
                    Circle().stroke(Color.ink, lineWidth: 3)
                }
            )
            .opacity(isEnabled ? 1 : 0.4)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct DoodleCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(maxWidth: 330)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 26).fill(Color.ink).offset(x: 4, y: 6)
                RoundedRectangle(cornerRadius: 26).fill(Color(hex: 0xFFFDF5))
                RoundedRectangle(cornerRadius: 26).stroke(Color.ink, lineWidth: 3.5)
            }
        )
        .padding(24)
    }
}

struct StarBadge: View {
    let filled: Bool
    let delay: Double
    @State private var shown = false

    var body: some View {
        Image(systemName: filled ? "star.fill" : "star")
            .font(.system(size: 46, weight: .bold))
            .foregroundStyle(filled ? Color(hex: 0xFFC933) : Color.ink.opacity(0.3))
            .scaleEffect(shown ? 1 : 0.2)
            .rotationEffect(.degrees(shown ? 0 : -40))
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(delay)) {
                    shown = true
                }
            }
    }
}

struct InkBar: View {
    let fraction: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.tip")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(Color.ink)
            GeometryReader { geo in
                let f = max(0, min(1, fraction))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.85))
                    Capsule()
                        .fill(f < 0.2 ? Color(hex: 0xEF476F) : Color(hex: 0x1C7ED6))
                        .frame(width: f * geo.size.width)
                    Capsule().stroke(Color.ink, lineWidth: 2.5)
                }
            }
            .frame(width: 140, height: 14)
        }
    }
}

struct ScreenHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(DoodleIconButtonStyle(fill: Color.white))
            Spacer()
            Text(title)
                .font(.doodle(30))
                .foregroundStyle(Color.ink)
            Spacer()
            Color.clear.frame(width: 48, height: 48)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
}

// MARK: - Game canvas

struct GameCanvas: View {
    @ObservedObject var engine: GameEngine
    let skin: CarSkin

    private var hint: String? {
        if engine.phase == .drawing && engine.path.count <= 1 {
            return "Draw a road from the car to the flag"
        }
        if engine.phase == .drawing && engine.level.number <= 2 {
            return "Now press GO!"
        }
        if engine.phase == .driving && engine.stuckTime > 0.6 && engine.inkLeft > 8 {
            return "The road ended. Keep drawing!"
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let frameID = engine.frame
            Canvas { context, size in
                _ = frameID
                render(context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fit = WorldFit(size: geo.size)
                        engine.touchChanged(fit.toWorld(value.location))
                    }
                    .onEnded { _ in
                        engine.touchEnded()
                    }
            )
        }
        .overlay(alignment: .bottom) {
            if let text = hint {
                Text(text)
                    .font(.doodle(16))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().stroke(Color.ink, lineWidth: 2.5))
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private func render(_ context: GraphicsContext, size: CGSize) {
        let fit = WorldFit(size: size)
        var g = context
        var jx: CGFloat = 0
        var jy: CGFloat = 0
        if engine.shake > 0 {
            jx = CGFloat.random(in: -1...1) * engine.shake * 0.5
            jy = CGFloat.random(in: -1...1) * engine.shake * 0.5
        }
        g.translateBy(x: fit.origin.x + jx, y: fit.origin.y + jy)
        g.scaleBy(x: fit.scale, y: fit.scale)

        let level = engine.level
        let t = engine.time

        // playfield
        let field = Path(roundedRect: CGRect(x: 0, y: 0, width: LevelFactory.worldW, height: LevelFactory.worldH),
                         cornerRadius: 22)
        g.fill(field, with: .color(Color.white.opacity(0.45)))
        g.stroke(field, with: .color(Color.ink.opacity(0.45)),
                 style: StrokeStyle(lineWidth: 2.5, dash: [8, 7]))

        Painter.finish(g, at: level.finish, time: t)
        for o in level.obstacles { Painter.obstacle(g, o) }
        for b in level.boosts { Painter.boost(g, at: b, time: t) }
        for i in level.stars.indices where !engine.starTaken[i] {
            Painter.star(g, at: level.stars[i], time: t + Double(i))
        }

        if engine.path.count > 1 {
            Painter.road(g, path: Painter.smooth(engine.path))
        }

        // pen ring: shows where to put your finger
        if (engine.phase == .drawing || engine.phase == .driving) && engine.inkLeft > 0.5 {
            let e = engine.penEnd
            var ringR: CGFloat = 19 + 2.5 * CGFloat(sin(t * 6))
            if engine.hintFlash > 0 { ringR += 10 }
            let color: Color = engine.blockedFlash > 0 ? Color(hex: 0xEF476F) : Color(hex: 0x12B886)
            let ring = Path(ellipseIn: CGRect(x: e.x - ringR, y: e.y - ringR, width: ringR * 2, height: ringR * 2))
            g.stroke(ring, with: .color(color),
                     style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [6, 5]))
        }

        for m in level.movers {
            Painter.sheep(g, at: m.position(at: t), r: m.r, facing: m.facing(at: t))
        }

        Painter.car(g, at: engine.carPos, angle: engine.carAngle, skin: skin, boosting: engine.boostTimer > 0)
        Painter.particles(g, engine.particles)
    }
}

// MARK: - Game screen

struct GameScreen: View {
    @EnvironmentObject var store: GameStore
    @StateObject private var engine: GameEngine
    @State private var ticker = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var showResult = false

    let levelNumber: Int
    let onExit: () -> Void
    let onNext: (Int) -> Void

    init(levelNumber: Int, onExit: @escaping () -> Void, onNext: @escaping (Int) -> Void) {
        self.levelNumber = levelNumber
        self.onExit = onExit
        self.onNext = onNext
        _engine = StateObject(wrappedValue: GameEngine(level: LevelFactory.make(levelNumber)))
    }

    private let green = Color(hex: 0x69DB7C)

    var body: some View {
        ZStack {
            PaperBackground(theme: PaperTheme.forIndex((levelNumber - 1) / GameStore.perWorld))

            VStack(spacing: 0) {
                topBar
                GameCanvas(engine: engine, skin: store.currentSkin)
                bottomBar
            }

            overlays
        }
        .animation(.easeInOut(duration: 0.25), value: engine.paused)
        .animation(.easeInOut(duration: 0.25), value: showResult)
        .onReceive(ticker) { now in
            engine.step(now: now)
        }
        .onChange(of: engine.phase) { _, newPhase in
            switch newPhase {
            case .won:
                store.record(level: levelNumber, earned: engine.earnedStars)
                delayResult()
            case .crashed, .outOfInk:
                delayResult()
            default:
                showResult = false
            }
        }
    }

    private func delayResult() {
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if engine.phase != .drawing && engine.phase != .driving {
                showResult = true
            }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                engine.paused = true
            } label: {
                Image(systemName: "pause.fill")
            }
            .buttonStyle(DoodleIconButtonStyle(fill: Color.white))

            VStack(alignment: .leading, spacing: 4) {
                Text("Level \(levelNumber)")
                    .font(.doodle(20))
                    .foregroundStyle(Color.ink)
                InkBar(fraction: engine.inkLeft / max(engine.level.ink, 1))
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < engine.collected ? "star.fill" : "star")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(i < engine.collected ? Color(hex: 0xFFC933) : Color.ink.opacity(0.35))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                engine.clearRoad()
            } label: {
                Image(systemName: "eraser.fill")
            }
            .buttonStyle(DoodleIconButtonStyle(fill: Color(hex: 0xFFE3E3)))
            .disabled(engine.phase != .drawing || engine.path.count <= 1)

            Button {
                engine.reset()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(DoodleIconButtonStyle(fill: Color(hex: 0xFFF3BF)))

            Button {
                engine.go()
            } label: {
                Text(engine.phase == .driving ? "Driving..." : "GO!")
                    .frame(minWidth: 110)
            }
            .buttonStyle(DoodleButtonStyle(fill: green, size: 26))
            .disabled(!engine.canGo)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: Overlays

    @ViewBuilder
    private var overlays: some View {
        if engine.paused {
            Color.black.opacity(0.35).ignoresSafeArea()
            DoodleCard {
                Text("Paused")
                    .font(.doodle(34))
                    .foregroundStyle(Color.ink)
                Button {
                    engine.paused = false
                } label: {
                    Text("Resume").frame(maxWidth: .infinity)
                }
                .buttonStyle(DoodleButtonStyle(fill: green))
                Button {
                    engine.reset()
                } label: {
                    Text("Restart").frame(maxWidth: .infinity)
                }
                .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0xFFD43B)))
                Button {
                    onExit()
                } label: {
                    Text("Levels").frame(maxWidth: .infinity)
                }
                .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0x74C0FC)))
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if engine.phase == .won && showResult {
            Color.black.opacity(0.35).ignoresSafeArea()
            DoodleCard {
                Text("Level complete!")
                    .font(.doodle(32))
                    .foregroundStyle(Color.ink)
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { i in
                        StarBadge(filled: i < engine.earnedStars, delay: Double(i) * 0.25)
                    }
                }
                Text(engine.collected >= 3 ? "Perfect run!" : "Collect all 3 stars for a perfect run")
                    .font(.doodle(15))
                    .foregroundStyle(Color.ink.opacity(0.75))
                    .multilineTextAlignment(.center)
                if levelNumber < GameStore.levelCount {
                    Button {
                        onNext(levelNumber + 1)
                    } label: {
                        Text("Next level").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DoodleButtonStyle(fill: green))
                } else {
                    Text("You finished every level!")
                        .font(.doodle(18))
                        .foregroundStyle(Color.ink)
                }
                HStack(spacing: 12) {
                    Button {
                        engine.reset()
                    } label: {
                        Text("Replay").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0xFFD43B), size: 20))
                    Button {
                        onExit()
                    } label: {
                        Text("Levels").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0x74C0FC), size: 20))
                }
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if (engine.phase == .crashed || engine.phase == .outOfInk) && showResult {
            Color.black.opacity(0.35).ignoresSafeArea()
            DoodleCard {
                Text(engine.phase == .crashed ? "Crash!" : "Out of ink!")
                    .font(.doodle(34))
                    .foregroundStyle(Color(hex: 0xEF476F))
                Text(engine.phase == .crashed
                     ? "A sheep got in the way. Watch the timing and try again."
                     : "Your road was too short. Try a straighter route.")
                    .font(.doodle(16))
                    .foregroundStyle(Color.ink.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button {
                    engine.reset()
                } label: {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(DoodleButtonStyle(fill: green))
                Button {
                    onExit()
                } label: {
                    Text("Levels").frame(maxWidth: .infinity)
                }
                .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0x74C0FC), size: 20))
            }
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var store: GameStore
    let onPlay: (Int) -> Void
    let onLevels: () -> Void
    let onGarage: () -> Void

    var body: some View {
        ZStack {
            PaperBackground(theme: PaperTheme.forIndex(0))

            VStack(spacing: 22) {
                Spacer(minLength: 20)
                titleBlock
                hero
                Spacer(minLength: 10)

                Button {
                    onPlay(store.nextLevel)
                } label: {
                    VStack(spacing: 0) {
                        Text("PLAY").font(.doodle(40))
                        Text("Level \(store.nextLevel)").font(.doodle(16))
                    }
                    .padding(.horizontal, 28)
                }
                .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0x69DB7C)))

                HStack(spacing: 14) {
                    Button(action: onLevels) {
                        Label("Levels", systemImage: "square.grid.3x3.fill")
                    }
                    .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0xFFD43B), size: 20))

                    Button(action: onGarage) {
                        Label("Garage", systemImage: "car.fill")
                    }
                    .buttonStyle(DoodleButtonStyle(fill: Color(hex: 0x74C0FC), size: 20))
                }

                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color(hex: 0xFFC933))
                    Text("\(store.totalStars) / \(store.maxStars)")
                        .font(.doodle(20))
                        .foregroundStyle(Color.ink)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(Color.ink, lineWidth: 2.5))

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: -10) {
            Text("Doodle").foregroundStyle(Color.ink)
            Text("Road").foregroundStyle(Color(hex: 0xEF476F))
        }
        .font(.doodle(68))
        .shadow(color: Color.ink.opacity(0.9), radius: 0, x: 3, y: 4)
        .rotationEffect(.degrees(-4))
    }

    private var hero: some View {
        let skin = store.currentSkin
        return TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let midY = size.height / 2
                var pts: [CGPoint] = []
                var x: CGFloat = -30
                while x <= size.width + 30 {
                    pts.append(CGPoint(x: x, y: midY + sin(x / 48) * 26))
                    x += 8
                }
                Painter.road(ctx, path: Painter.smooth(pts))
                let cx = CGFloat((t * 110).truncatingRemainder(dividingBy: Double(size.width + 100))) - 50
                let cy = midY + sin(cx / 48) * 26
                let slope = cos(cx / 48) * 26 / 48
                Painter.car(ctx, at: CGPoint(x: cx, y: cy), angle: atan(slope), skin: skin, boosting: false)
            }
        }
        .frame(height: 130)
    }
}

// MARK: - Level select

struct LevelSelectView: View {
    @EnvironmentObject var store: GameStore
    let onBack: () -> Void
    let onPlay: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)

    var body: some View {
        ZStack {
            PaperBackground(theme: PaperTheme.forIndex(0))
            VStack(spacing: 8) {
                ScreenHeader(title: "Levels", onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(0..<4, id: \.self) { w in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(PaperTheme.names[w])
                                    .font(.doodle(22))
                                    .foregroundStyle(Color.ink)
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(1...GameStore.perWorld, id: \.self) { i in
                                        cell(w * GameStore.perWorld + i)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ n: Int) -> some View {
        let unlocked = store.isUnlocked(n)
        let earned = store.stars[n - 1]
        Button {
            if unlocked { onPlay(n) }
        } label: {
            VStack(spacing: 3) {
                if unlocked {
                    Text("\(n)")
                        .font(.doodle(24))
                        .foregroundStyle(Color.ink)
                    HStack(spacing: 1) {
                        ForEach(0..<3, id: \.self) { i in
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(i < earned ? Color(hex: 0xFFC933) : Color.ink.opacity(0.18))
                        }
                    }
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.ink.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.ink).offset(x: 2, y: 3)
                    RoundedRectangle(cornerRadius: 14).fill(unlocked ? Color.white : Color(hex: 0xE9ECEF))
                    RoundedRectangle(cornerRadius: 14).stroke(Color.ink, lineWidth: 2.5)
                }
            )
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
    }
}

// MARK: - Garage

struct GarageView: View {
    @EnvironmentObject var store: GameStore
    let onBack: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            PaperBackground(theme: PaperTheme.forIndex(1))
            VStack(spacing: 8) {
                ScreenHeader(title: "Garage", onBack: onBack)
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").foregroundStyle(Color(hex: 0xFFC933))
                    Text("\(store.totalStars) stars collected")
                        .font(.doodle(18))
                        .foregroundStyle(Color.ink)
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(CarSkin.all) { skin in
                            card(skin)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private func card(_ skin: CarSkin) -> some View {
        let unlocked = store.isSkinUnlocked(skin)
        let selected = store.selectedSkin == skin.id
        Button {
            if unlocked {
                store.selectedSkin = skin.id
                Haptics.tap()
            }
        } label: {
            VStack(spacing: 6) {
                Canvas { ctx, size in
                    var c = ctx
                    c.translateBy(x: size.width / 2, y: size.height / 2)
                    c.scaleBy(x: 2.3, y: 2.3)
                    Painter.car(c, at: .zero, angle: -CGFloat.pi / 8, skin: skin, boosting: false)
                }
                .frame(height: 70)
                .opacity(unlocked ? 1 : 0.35)

                Text(skin.name)
                    .font(.doodle(20))
                    .foregroundStyle(Color.ink)

                if selected {
                    Text("Selected").font(.doodle(14)).foregroundStyle(Color(hex: 0x2B8A3E))
                } else if unlocked {
                    Text("Tap to use").font(.doodle(14)).foregroundStyle(Color.ink.opacity(0.6))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill")
                        Text("\(skin.cost)")
                        Image(systemName: "star.fill")
                    }
                    .font(.doodle(14))
                    .foregroundStyle(Color.ink.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color.ink).offset(x: 3, y: 4)
                    RoundedRectangle(cornerRadius: 20).fill(selected ? Color(hex: 0xD3F9D8) : Color.white)
                    RoundedRectangle(cornerRadius: 20).stroke(Color.ink, lineWidth: 3)
                }
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Root

enum AppScreen: Equatable {
    case home
    case levels
    case garage
    case game(Int)
}

struct ContentView: View {
    @StateObject private var store = GameStore()
    @State private var screen: AppScreen = .home

    var body: some View {
        ZStack {
            switch screen {
            case .home:
                HomeView(
                    onPlay: { go(.game($0)) },
                    onLevels: { go(.levels) },
                    onGarage: { go(.garage) }
                )
                .transition(.opacity)
            case .levels:
                LevelSelectView(
                    onBack: { go(.home) },
                    onPlay: { go(.game($0)) }
                )
                .transition(.opacity)
            case .garage:
                GarageView(onBack: { go(.home) })
                    .transition(.opacity)
            case .game(let n):
                GameScreen(
                    levelNumber: n,
                    onExit: { go(.levels) },
                    onNext: { go(.game($0)) }
                )
                .id(n)
                .transition(.opacity)
            }
        }
        .environmentObject(store)
        .preferredColorScheme(.light)
    }

    private func go(_ s: AppScreen) {
        withAnimation(.easeInOut(duration: 0.25)) {
            screen = s
        }
    }
}

#Preview {
    ContentView()
}
