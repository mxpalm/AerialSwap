import Foundation
import simd

/// A particle system simulated on the CPU, deterministically: a fixed time step and a seeded random source, so the
/// same time always gives the same frame (videos baked twice match, loops can be checked). With `loop(every:)` it
/// repeats exactly, for videos that loop without a seam.
///
/// Read from a particle JSON: emitters spawn particles (in a sphere or box around their origin), initializers give
/// each its starting values, operators change them over its life, and renderers say how they're drawn. The scene's
/// `instanceoverride` scales counts, rates, sizes, alphas, lifetimes, speeds and colors.
final class ParticleSystem {
    struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float> = .zero
        var rotation: SIMD3<Float> = .zero
        var angularVelocity: SIMD3<Float> = .zero
        var size: Float = 20
        var alpha: Float = 1
        var color: SIMD3<Float> = .one
        var age: Float = 0
        var lifetime: Float = 1
        /// Per-particle randomness for operators (oscillation frequencies, turbulence speeds…).
        var seed: UInt32
        /// The sprite-sheet frame chosen at random (`randomframe` animation).
        var frame: Int = 0
    }

    enum Renderer {
        case sprite
        /// Stretched along the velocity: length = size × clamp(speed × `length`, `minimum`, `maximum`). Tapered, it
        /// runs back from the particle only and narrows and fades toward its end (`ropetrail`).
        case trail(length: Float, minimum: Float, maximum: Float, tapered: Bool = false)
        /// One ribbon through the particles in the order they were born, as wide as each is big, smoothed with
        /// `subdivision` points between two particles.
        case rope(subdivision: Int)
    }

    /// How a sprite sheet animates: a random frame per particle, or the sequence played `multiplier` times over each
    /// particle's life.
    enum Animation { case sequence(multiplier: Float), randomFrame }

    static let step: Float = 1 / 120

    let maxCount: Int
    /// The material the particles draw with (`materials/…json`).
    let materialPath: String?
    let renderers: [Renderer]
    let animation: Animation
    /// Child systems, each placed at an offset from this one.
    let children: [(system: ParticleSystem, origin: SIMD3<Float>)]
    /// What the definition uses that isn't simulated (unknown renderers, remapped values…).
    let unsupported: Set<String>

    private let emitters: [Emitter]
    private let initializers: [Initializer]
    private let operators: [Operator]
    private let startTime: Float
    private let seed: UInt64
    private let overrides: Overrides

    private(set) var particles: [Particle] = []
    private var random: RandomSource
    private var time: Float = 0
    private var emitted: [Float]

    /// Loop mode: everything repeats every `steps` steps of `dt`.
    private struct Cycle {
        let steps: Int
        let dt: Float
        let seconds: Float
        /// Particles each emitter spawns per cycle.
        let spawns: [Int]
        /// Cycles to run from empty before the state repeats (every particle alive then was born inside them).
        let warmUp: Int
    }

    private var cycle: Cycle?
    private var phase = 0
    private var warmed = false

    // MARK: - Reading the definition

    private struct Emitter {
        enum Shape { case sphere, box }
        var shape = Shape.sphere
        var origin = SIMD3<Float>.zero
        var distanceMin = SIMD3<Float>.zero
        var distanceMax = SIMD3<Float>(repeating: 256)
        var directions = SIMD3<Float>(1, 1, 0)
        /// Per axis: 1 only positive, -1 only negative, 0 either.
        var sign = SIMD3<Float>.zero
        var rate: Float = 5
        var speedMin: Float = 0
        var speedMax: Float = 0
        /// Seconds the emitter runs (0: forever).
        var duration: Float = 0
    }

    private enum Initializer {
        case lifetime(Float, Float)
        case size(Float, Float, exponent: Float)
        case velocity(SIMD3<Float>, SIMD3<Float>, exponent: Float)
        case color(SIMD3<Float>, SIMD3<Float>)
        case alpha(Float, Float)
        case rotation(SIMD3<Float>, SIMD3<Float>)
        case angularVelocity(SIMD3<Float>, SIMD3<Float>)
        case turbulentVelocity(speedMin: Float, speedMax: Float, scale: Float, offset: Float)
    }

    private enum Operator {
        case movement(gravity: SIMD3<Float>, drag: Float)
        case angularMovement(force: SIMD3<Float>, drag: Float)
        case turbulence(speedMin: Float, speedMax: Float, scale: Float, timeScale: Float)
        case attract(point: SIMD3<Float>, scale: Float, threshold: Float)
        case alphaFade(fadeIn: Float, fadeOut: Float)
        case sizeChange(start: Float, end: Float, from: Float, to: Float)
        case colorChange(start: Float, end: Float, from: SIMD3<Float>, to: SIMD3<Float>)
        case alphaChange(start: Float, end: Float, from: Float, to: Float)
        case oscillatePosition(frequency: ClosedRange<Float>, scale: ClosedRange<Float>, phase: ClosedRange<Float>, mask: SIMD3<Float>)
        case oscillateAlpha(frequency: ClosedRange<Float>, scale: ClosedRange<Float>, phase: ClosedRange<Float>)
        case oscillateSize(frequency: ClosedRange<Float>, scale: ClosedRange<Float>, phase: ClosedRange<Float>)
    }

    /// The scene's `instanceoverride`: multipliers on the definition's values, and control point positions.
    struct Overrides {
        var count: Float = 1, rate: Float = 1, size: Float = 1, alpha: Float = 1, lifetime: Float = 1, speed: Float = 1
        var color = SIMD3<Float>.one
        var controlPoints: [Int: SIMD3<Float>] = [:]

        init(_ json: [String: SceneJSON]) {
            func number(_ key: String) -> Float? { json[key]?.number.map { Float($0) } }
            count = number("count") ?? 1
            rate = number("rate") ?? 1
            size = number("size") ?? 1
            alpha = number("alpha") ?? 1
            lifetime = number("lifetime") ?? 1
            speed = number("speed") ?? 1
            if let c = json["colorn"]?.vector, c.count >= 3 {
                color = SIMD3(Float(c[0]), Float(c[1]), Float(c[2]))
            } else if let c = json["color"]?.vector, c.count >= 3 {
                color = SIMD3(Float(c[0]), Float(c[1]), Float(c[2])) / 255
            }
            for (key, value) in json where key.hasPrefix("controlpoint") {
                if let index = Int(key.dropFirst("controlpoint".count)), let v = ParticleSystem.vector(value) { controlPoints[index] = v }
            }
        }
    }

    /// `load(path)` reads child definitions (nil when missing); `seed` makes the system's randomness its own.
    init(definition json: SceneJSON, overrides: Overrides, seed: UInt64, depth: Int = 0, load: (String) -> SceneJSON?) {
        self.overrides = overrides
        self.seed = seed
        random = RandomSource(seed: seed)
        var unsupported = Set<String>()

        materialPath = json["material"]?.string
        maxCount = max(0, min(100_000, Int((Float(json["maxcount"]?.number ?? 100) * overrides.count).rounded())))
        startTime = Float(min(max(json["starttime"]?.number ?? 0, 0), 60))
        animation = json["animationmode"]?.string == "randomframe"
            ? .randomFrame : .sequence(multiplier: Float(json["sequencemultiplier"]?.number ?? 1))

        var controlPoints: [Int: SIMD3<Float>] = [:]
        for point in json["controlpoint"]?.array ?? [] {
            guard let id = point["id"]?.number else { continue }
            controlPoints[Int(id)] = Self.vector(point["offset"]) ?? .zero
        }
        controlPoints.merge(overrides.controlPoints) { _, new in new }

        emitters = (json["emitter"]?.array ?? []).compactMap { e in
            var emitter = Emitter()
            switch e["name"]?.string {
            case "sphererandom": emitter.shape = .sphere
            case "boxrandom": emitter.shape = .box
            case let name:
                unsupported.insert("emitter \(name ?? "?")")
                return nil
            }
            emitter.origin = Self.vector(e["origin"]) ?? .zero
            emitter.distanceMin = Self.vector(e["distancemin"], splat: true) ?? .zero
            emitter.distanceMax = Self.vector(e["distancemax"], splat: true) ?? SIMD3(repeating: 256)
            emitter.directions = Self.vector(e["directions"]) ?? SIMD3(1, 1, 0)
            emitter.sign = Self.vector(e["sign"]) ?? .zero
            emitter.rate = Float(e["rate"]?.number ?? 5) * overrides.rate
            emitter.speedMin = Float(e["speedmin"]?.number ?? 0)
            emitter.speedMax = Float(e["speedmax"]?.number ?? e["speedmin"]?.number ?? 0)
            emitter.duration = Float(e["duration"]?.number ?? 0)
            return emitter
        }
        emitted = Array(repeating: 0, count: emitters.count)

        initializers = (json["initializer"]?.array ?? []).compactMap { i in
            func number(_ key: String, _ fallback: Float) -> Float { i[key]?.number.map { Float($0) } ?? fallback }
            func vector(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> { Self.vector(i[key], splat: true) ?? fallback }
            switch i["name"]?.string {
            case "lifetimerandom": return .lifetime(number("min", 1), number("max", 1))
            case "sizerandom": return .size(number("min", 20), number("max", 20), exponent: number("exponent", 1))
            case "velocityrandom": return .velocity(vector("min", .zero), vector("max", .zero), exponent: number("exponent", 1))
            case "colorrandom": return .color(vector("min", SIMD3(repeating: 255)) / 255, vector("max", SIMD3(repeating: 255)) / 255)
            case "alpharandom": return .alpha(number("min", 1), number("max", 1))
            case "rotationrandom": return .rotation(vector("min", .zero), vector("max", SIMD3(0, 0, 2 * .pi)))
            case "angularvelocityrandom": return .angularVelocity(vector("min", .zero), vector("max", .zero))
            case "turbulentvelocityrandom":
                return .turbulentVelocity(speedMin: number("speedmin", 100), speedMax: number("speedmax", 250),
                                          scale: number("scale", 1), offset: number("offset", 0))
            case let name:
                unsupported.insert("initializer \(name ?? "?")")
                return nil
            }
        }

        operators = (json["operator"]?.array ?? []).compactMap { o in
            func number(_ key: String, _ fallback: Float) -> Float { o[key]?.number.map { Float($0) } ?? fallback }
            func vector(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> { Self.vector(o[key], splat: true) ?? fallback }
            func range(_ name: String, _ min: Float, _ max: Float) -> ClosedRange<Float> {
                let lower = number(name + "min", min), upper = number(name + "max", max)
                return Swift.min(lower, upper) ... Swift.max(lower, upper)
            }
            switch o["name"]?.string {
            case "movement": return .movement(gravity: vector("gravity", .zero), drag: number("drag", 0))
            case "angularmovement": return .angularMovement(force: vector("force", .zero), drag: number("drag", 0))
            case "turbulence":
                return .turbulence(speedMin: number("speedmin", 500), speedMax: number("speedmax", 1000),
                                   scale: number("scale", 0.005), timeScale: number("timescale", 1))
            case "controlpointattract":
                let point = controlPoints[Int(number("controlpoint", 0))] ?? .zero
                return .attract(point: point + vector("origin", .zero), scale: number("scale", 100), threshold: number("threshold", .infinity))
            case "alphafade": return .alphaFade(fadeIn: number("fadeintime", 0.5), fadeOut: number("fadeouttime", 0.5))
            case "sizechange":
                return .sizeChange(start: number("starttime", 0), end: number("endtime", 1), from: number("startvalue", 1), to: number("endvalue", 0))
            case "colorchange":
                return .colorChange(start: number("starttime", 0), end: number("endtime", 1),
                                    from: vector("startvalue", .one), to: vector("endvalue", .one))
            case "alphachange":
                return .alphaChange(start: number("starttime", 0), end: number("endtime", 1), from: number("startvalue", 1), to: number("endvalue", 0))
            case "oscillateposition":
                return .oscillatePosition(frequency: range("frequency", 0, 10), scale: range("scale", 0, 10), phase: range("phase", 0, 1),
                                          mask: vector("mask", SIMD3(1, 1, 0)))
            case "oscillatealpha":
                return .oscillateAlpha(frequency: range("frequency", 0, 10), scale: range("scale", 0, 1), phase: range("phase", 0, 1))
            case "oscillatesize":
                return .oscillateSize(frequency: range("frequency", 0, 10), scale: range("scale", 0.8, 1.2), phase: range("phase", 0, 1))
            case let name:
                unsupported.insert("operator \(name ?? "?")")
                return nil
            }
        }

        renderers = (json["renderer"]?.array ?? []).compactMap { r in
            switch r["name"]?.string {
            case "sprite": return .sprite
            case "spritetrail":
                return .trail(length: Float(r["length"]?.number ?? 0.05), minimum: Float(r["minlength"]?.number ?? 0),
                              maximum: Float(r["maxlength"]?.number ?? 10))
            case "ropetrail":
                return .trail(length: Float(r["length"]?.number ?? 0.05), minimum: Float(r["minlength"]?.number ?? 0),
                              maximum: Float(r["maxlength"]?.number ?? 10), tapered: true)
            case "rope":
                return .rope(subdivision: min(max(Int(r["subdivision"]?.number ?? 0), 0), 16))
            case let name:
                unsupported.insert("renderer \(name ?? "?")")
                return nil
            }
        }

        var children: [(ParticleSystem, SIMD3<Float>)] = []
        if depth < 4 {
            for (index, child) in (json["children"]?.array ?? []).prefix(16).enumerated() {
                guard let path = child["name"]?.string, let definition = load(path) else { continue }
                let system = ParticleSystem(definition: definition, overrides: overrides,
                                            seed: seed &* 31 &+ UInt64(index + 1), depth: depth + 1, load: load)
                children.append((system, Self.vector(child["origin"]) ?? .zero))
                unsupported.formUnion(system.unsupported)
            }
        }
        self.children = children
        self.unsupported = unsupported
    }

    /// A vector from `"x y z"` or a number (`splat`: a number fills every axis, else it's x).
    static func vector(_ json: SceneJSON?, splat: Bool = false) -> SIMD3<Float>? {
        guard let v = json?.vector else { return nil }
        if v.count == 1 { return splat ? SIMD3(repeating: Float(v[0])) : SIMD3(Float(v[0]), 0, 0) }
        return SIMD3(Float(v[0]), Float(v[1]), v.count > 2 ? Float(v[2]) : 0)
    }

    // MARK: - Simulating

    /// Makes the system repeat exactly every `period` seconds, or run freely as Wallpaper Engine runs it (nil).
    ///
    /// In a loop, spawns follow a schedule that repeats each period, each spawn's randomness comes from its place in
    /// that schedule, and the turbulence field drifts around a circle instead of along a line, so after a warm-up the
    /// state at t and t + period is the same, bit for bit. Rates are capped so the expected count stays within
    /// `maxcount`: turning spawns away when full would make the count depend on history.
    func loop(every period: Double?) {
        particles = []
        phase = 0
        warmed = false
        random = RandomSource(seed: seed)
        time = 0
        emitted = Array(repeating: 0, count: emitters.count)
        defer { for child in children { child.system.loop(every: period) } }
        guard let period, period > 0 else {
            cycle = nil
            return
        }
        let steps = max(1, Int((Float(period) / Self.step).rounded()))
        var meanLife: Float = 1, maxLife: Float = 1
        for case .lifetime(let a, let b) in initializers {
            meanLife = (a + b) / 2
            maxLife = max(a, b)
        }
        meanLife = max(0.01, meanLife * overrides.lifetime)
        maxLife = max(0.01, maxLife * overrides.lifetime)
        let total = emitters.reduce(0) { $0 + $1.rate }
        let cap = total * meanLife > Float(maxCount) && total > 0 ? Float(maxCount) / (total * meanLife) : 1
        cycle = Cycle(steps: steps, dt: Float(period) / Float(steps), seconds: Float(period),
                      spawns: emitters.map { max(0, Int(($0.rate * cap * Float(period)).rounded())) },
                      warmUp: max(1, Int(((maxLife + Float(period) / Float(steps)) / Float(period)).rounded(.up))))
    }

    /// Advances to `time` seconds into the wallpaper (the system has already run `starttime` seconds by then).
    /// Going back starts over; in a loop it goes on to the same point of the next cycle instead.
    func advance(to time: Double) {
        defer { for child in children { child.system.advance(to: time) } }
        if let cycle {
            if !warmed {
                for i in 0 ..< cycle.warmUp * cycle.steps { update(cycle.dt, step: i % cycle.steps) }
                phase = 0
                warmed = true
            }
            let target = ((Int((time / Double(cycle.dt)).rounded()) % cycle.steps) + cycle.steps) % cycle.steps
            while phase != target {
                update(cycle.dt, step: phase)
                phase = (phase + 1) % cycle.steps
            }
            return
        }
        let target = Float(time) + startTime
        if target < self.time {
            particles = []
            random = RandomSource(seed: seed)
            self.time = 0
            emitted = Array(repeating: 0, count: emitters.count)
        }
        while self.time + Self.step <= target {
            update(Self.step, step: nil)
            self.time += Self.step
        }
    }

    /// One step of `dt`; `step` is the step's place in the loop's cycle (nil when running freely).
    private func update(_ dt: Float, step: Int?) {
        // How far the turbulence field has drifted: along a line, or around a circle once per cycle.
        func drift(_ timeScale: Float) -> SIMD2<Float> {
            let speed = timeScale * 0.1
            guard let step, let cycle else { return SIMD2(1, -0.7) * time * speed }
            let angle = 2 * Float.pi * Float(step) / Float(cycle.steps)
            let radius = speed * 1.22 * cycle.seconds / (2 * .pi)
            return SIMD2(cos(angle), sin(angle)) * radius
        }

        // Age, and let the dead go.
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.lifetime }

        for i in particles.indices {
            var p = particles[i]
            for o in operators {
                switch o {
                case .movement(let gravity, let drag):
                    p.velocity += gravity * dt
                    p.velocity *= max(0, 1 - drag * dt)
                    p.position += p.velocity * dt
                case .angularMovement(let force, let drag):
                    p.angularVelocity += force * dt
                    p.angularVelocity *= max(0, 1 - drag * dt)
                    p.rotation += p.angularVelocity * dt
                case .turbulence(let speedMin, let speedMax, let scale, let timeScale):
                    let speed = speedMin + (speedMax - speedMin) * Self.hash(p.seed, 1)
                    let direction = Self.flow(p.position * scale, drift: drift(timeScale))
                    p.velocity += direction * speed * dt
                case .attract(let point, let scale, let threshold):
                    let delta = point - p.position
                    let distance = simd_length(delta)
                    if distance > 0.001, distance < threshold { p.velocity += delta / distance * scale * dt }
                default:
                    break
                }
            }
            particles[i] = p
        }

        if let step, let cycle {
            for (index, emitter) in emitters.enumerated() {
                if emitter.duration > 0, Float(step) * dt > emitter.duration { continue }
                // The cycle's spawns spread evenly over its steps; each gets the randomness of its number.
                let count = cycle.spawns[index]
                for number in step * count / cycle.steps ..< (step + 1) * count / cycle.steps where particles.count < maxCount * 4 {
                    var random = RandomSource(seed: seed ^ (UInt64(index + 1) << 48) ^ UInt64(number) &* 0x9E37_79B9_7F4A_7C15)
                    particles.append(spawn(emitter, random: &random))
                }
            }
            return
        }
        for (index, emitter) in emitters.enumerated() {
            if emitter.duration > 0, time > emitter.duration { continue }
            emitted[index] += emitter.rate * dt
            while emitted[index] >= 1 {
                emitted[index] -= 1
                guard particles.count < maxCount else { continue }
                var random = self.random
                particles.append(spawn(emitter, random: &random))
                self.random = random
            }
        }
    }

    private func spawn(_ emitter: Emitter, random: inout RandomSource) -> Particle {
        var direction: SIMD3<Float>
        var offset: SIMD3<Float>
        switch emitter.shape {
        case .sphere:
            // A random direction, its length between the distances, squashed per axis by `directions`.
            repeat {
                direction = SIMD3(random.next() * 2 - 1, random.next() * 2 - 1, random.next() * 2 - 1)
            } while simd_length_squared(direction) > 1 || simd_length_squared(direction) < 1e-6
            direction = simd_normalize(direction)
            let distance = emitter.distanceMin.x + (emitter.distanceMax.x - emitter.distanceMin.x) * random.next()
            offset = direction * distance * emitter.directions
        case .box:
            offset = SIMD3(random.next() * 2 - 1, random.next() * 2 - 1, random.next() * 2 - 1) * emitter.distanceMax
            direction = simd_length_squared(offset) > 0 ? simd_normalize(offset) : .zero
        }
        for axis in 0 ..< 3 where emitter.sign[axis] != 0 {
            offset[axis] = abs(offset[axis]) * (emitter.sign[axis] > 0 ? 1 : -1)
        }
        var p = Particle(position: emitter.origin + offset, seed: UInt32(truncatingIfNeeded: random.bits()))
        let speed = emitter.speedMin + (emitter.speedMax - emitter.speedMin) * random.next()
        p.velocity = direction * speed * emitter.directions

        for i in initializers {
            switch i {
            case .lifetime(let a, let b): p.lifetime = a + (b - a) * random.next()
            case .size(let a, let b, let exponent): p.size = a + (b - a) * pow(random.next(), max(exponent, 0.01))
            case .velocity(let a, let b, let exponent):
                let t = SIMD3(pow(random.next(), exponent), pow(random.next(), exponent), pow(random.next(), exponent))
                p.velocity += a + (b - a) * t
            case .color(let a, let b): p.color = a + (b - a) * random.next()
            case .alpha(let a, let b): p.alpha = a + (b - a) * random.next()
            case .rotation(let a, let b): p.rotation = a + (b - a) * SIMD3(random.next(), random.next(), random.next())
            case .angularVelocity(let a, let b): p.angularVelocity = a + (b - a) * SIMD3(random.next(), random.next(), random.next())
            case .turbulentVelocity(let speedMin, let speedMax, let scale, let offset):
                let speed = speedMin + (speedMax - speedMin) * random.next()
                p.velocity += Self.flow(p.position * scale * 0.01 + offset, drift: .zero) * speed
            }
        }
        p.lifetime = max(0.01, p.lifetime * overrides.lifetime)
        p.size *= overrides.size
        p.alpha *= overrides.alpha
        p.color *= overrides.color
        p.velocity *= overrides.speed
        p.frame = Int(random.bits() & 0xFFFF)
        return p
    }

    // MARK: - Drawing

    /// A particle as drawn: life's changes, oscillations and fades applied.
    struct Sprite {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var rotation: Float
        var size: Float
        var color: SIMD4<Float>
        /// 0 at birth, 1 at death.
        var life: Float
        var frame: Int
    }

    func sprites() -> [Sprite] {
        particles.map { p in
            let life = min(1, p.age / p.lifetime)
            var position = p.position, size = p.size, alpha = p.alpha, color = p.color
            func ramp(_ start: Float, _ end: Float) -> Float { end > start ? min(max((life - start) / (end - start), 0), 1) : (life >= end ? 1 : 0) }
            func wave(_ frequency: ClosedRange<Float>, _ phase: ClosedRange<Float>, salt: UInt32) -> Float {
                let f = frequency.lowerBound + (frequency.upperBound - frequency.lowerBound) * Self.hash(p.seed, salt)
                let ph = phase.lowerBound + (phase.upperBound - phase.lowerBound) * Self.hash(p.seed, salt + 1)
                return sin(2 * .pi * (f * p.age + ph))
            }
            for (index, o) in operators.enumerated() {
                let salt = UInt32(index * 8 + 16)
                switch o {
                case .alphaFade(let fadeIn, let fadeOut):
                    if fadeIn > 0, life < fadeIn { alpha *= life / fadeIn }
                    if life > fadeOut, fadeOut < 1 { alpha *= max(0, (1 - life) / (1 - fadeOut)) }
                case .sizeChange(let start, let end, let from, let to): size *= from + (to - from) * ramp(start, end)
                case .colorChange(let start, let end, let from, let to): color *= from + (to - from) * ramp(start, end)
                case .alphaChange(let start, let end, let from, let to): alpha *= from + (to - from) * ramp(start, end)
                case .oscillatePosition(let frequency, let scale, let phase, let mask):
                    let amplitude = scale.lowerBound + (scale.upperBound - scale.lowerBound) * Self.hash(p.seed, salt + 2)
                    position += SIMD3(wave(frequency, phase, salt: salt), wave(frequency, phase, salt: salt + 3), 0) * amplitude * mask
                case .oscillateAlpha(let frequency, let scale, let phase):
                    alpha *= scale.lowerBound + (scale.upperBound - scale.lowerBound) * (wave(frequency, phase, salt: salt) * 0.5 + 0.5)
                case .oscillateSize(let frequency, let scale, let phase):
                    size *= scale.lowerBound + (scale.upperBound - scale.lowerBound) * (wave(frequency, phase, salt: salt) * 0.5 + 0.5)
                default:
                    break
                }
            }
            return Sprite(position: position, velocity: p.velocity, rotation: p.rotation.z, size: max(0, size),
                          color: SIMD4(color, min(max(alpha, 0), 1)), life: life, frame: p.frame)
        }
    }

    // MARK: - Randomness and noise

    /// A uniform value in [0, 1) from a particle's seed and a salt, the same every time.
    static func hash(_ seed: UInt32, _ salt: UInt32) -> Float {
        var x = seed &* 0x9E37_79B9 ^ salt &* 0x85EB_CA6B
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return Float(x >> 8) / Float(1 << 24)
    }

    /// A smooth 2D direction field, moved by `drift` (the gradient of value noise turned 90°, so it swirls instead of
    /// converging).
    static func flow(_ p: SIMD3<Float>, drift: SIMD2<Float>) -> SIMD3<Float> {
        guard p.x.isFinite, p.y.isFinite, abs(p.x) < 1e6, abs(p.y) < 1e6 else { return SIMD3(1, 0, 0) }
        func noise(_ x: Float, _ y: Float) -> Float {
            let ix = floor(x), iy = floor(y), fx = x - ix, fy = y - iy
            func corner(_ i: Float, _ j: Float) -> Float {
                hash(UInt32(bitPattern: Int32(truncatingIfNeeded: Int(i))) &* 1973 &+ UInt32(bitPattern: Int32(truncatingIfNeeded: Int(j))) &* 9277, 7)
            }
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let a = corner(ix, iy), b = corner(ix + 1, iy), c = corner(ix, iy + 1), d = corner(ix + 1, iy + 1)
            return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
        }
        let x = p.x + drift.x, y = p.y + drift.y, e: Float = 0.01
        let dx = (noise(x + e, y) - noise(x - e, y)) / (2 * e)
        let dy = (noise(x, y + e) - noise(x, y - e)) / (2 * e)
        let v = SIMD3<Float>(dy, -dx, 0)
        let length = simd_length(v)
        return length > 1e-5 ? v / length : SIMD3(1, 0, 0)
    }
}

/// PCG-style random numbers from a seed.
struct RandomSource {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }

    mutating func bits() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var x = state
        x ^= x >> 33
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 33
        return x
    }

    /// Uniform in [0, 1).
    mutating func next() -> Float { Float(bits() >> 40) / Float(1 << 24) }
}
