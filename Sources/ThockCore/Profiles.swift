import Foundation

/// Physical-model parameters describing a switch + case combination.
public struct ProfileSpec: Equatable, Sendable {
    public var bodyHz: Double          // case / plate resonance
    public var bodyDecay: Double
    public var bodyAmp: Double
    public var overtones: [(ratio: Double, amp: Double)]
    public var bottomHz: Double        // bottom-out impact colour
    public var bottomDecay: Double
    public var bottomAmp: Double
    public var bottomDelay: Double     // time from actuation to bottom-out
    public var clickHz: Double         // click jacket / leaf (0 amp = linear or non-clicky)
    public var clickAmp: Double
    public var clickDecay: Double
    public var bumpHz: Double          // tactile bump
    public var bumpAmp: Double
    public var springHz: Double
    public var springAmp: Double
    public var upAmp: Double           // release knock
    public var upClick: Double         // release click (clicky switches)
    public var brightnessHz: Double
    public var level: Float
    public var upLevel: Float

    public static func == (a: ProfileSpec, b: ProfileSpec) -> Bool {
        a.bodyHz == b.bodyHz && a.bodyDecay == b.bodyDecay && a.bottomHz == b.bottomHz && a.clickAmp == b.clickAmp
            && a.bumpAmp == b.bumpAmp && a.brightnessHz == b.brightnessHz
    }
}

public struct SoundProfile: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let spec: ProfileSpec
}

public enum SoundProfiles {
    public static let all: [SoundProfile] = [
        SoundProfile(id: "mx-blue", name: "Cherry MX Blue",
                     summary: "Sharp, clicky and crisp, with a loud click on press and release.",
                     spec: ProfileSpec(bodyHz: 640, bodyDecay: 0.040, bodyAmp: 0.7, overtones: [(2.3, 0.25), (3.7, 0.12)],
                                       bottomHz: 2200, bottomDecay: 0.020, bottomAmp: 0.8, bottomDelay: 0.011,
                                       clickHz: 3600, clickAmp: 1.1, clickDecay: 0.010, bumpHz: 0, bumpAmp: 0,
                                       springHz: 5200, springAmp: 0.25, upAmp: 0.6, upClick: 0.55,
                                       brightnessHz: 9000, level: 0.80, upLevel: 0.60)),
        SoundProfile(id: "mx-red", name: "Cherry MX Red",
                     summary: "Smooth linear switch. Soft, deep and quiet.",
                     spec: ProfileSpec(bodyHz: 170, bodyDecay: 0.085, bodyAmp: 1.0, overtones: [(2.0, 0.2)],
                                       bottomHz: 900, bottomDecay: 0.030, bottomAmp: 0.6, bottomDelay: 0.003,
                                       clickHz: 0, clickAmp: 0, clickDecay: 0, bumpHz: 0, bumpAmp: 0,
                                       springHz: 4200, springAmp: 0.12, upAmp: 0.35, upClick: 0,
                                       brightnessHz: 4500, level: 0.75, upLevel: 0.45)),
        SoundProfile(id: "mx-brown", name: "Cherry MX Brown",
                     summary: "Quiet tactile bump with a mellow, rounded landing.",
                     spec: ProfileSpec(bodyHz: 240, bodyDecay: 0.065, bodyAmp: 0.9, overtones: [(2.2, 0.22)],
                                       bottomHz: 1300, bottomDecay: 0.025, bottomAmp: 0.65, bottomDelay: 0.006,
                                       clickHz: 0, clickAmp: 0, clickDecay: 0, bumpHz: 1500, bumpAmp: 0.45,
                                       springHz: 4600, springAmp: 0.15, upAmp: 0.4, upClick: 0,
                                       brightnessHz: 5500, level: 0.75, upLevel: 0.50)),
        SoundProfile(id: "gateron", name: "Gateron Yellow",
                     summary: "Buttery smooth and slightly higher pitched, with a light creamy sound.",
                     spec: ProfileSpec(bodyHz: 330, bodyDecay: 0.058, bodyAmp: 0.85, overtones: [(2.1, 0.25), (3.4, 0.10)],
                                       bottomHz: 1600, bottomDecay: 0.022, bottomAmp: 0.55, bottomDelay: 0.003,
                                       clickHz: 0, clickAmp: 0, clickDecay: 0, bumpHz: 0, bumpAmp: 0,
                                       springHz: 4800, springAmp: 0.22, upAmp: 0.4, upClick: 0,
                                       brightnessHz: 7000, level: 0.72, upLevel: 0.50)),
        SoundProfile(id: "holy-panda", name: "Holy Panda",
                     summary: "Deep, rounded \"thock\" with a pronounced tactile bump.",
                     spec: ProfileSpec(bodyHz: 135, bodyDecay: 0.120, bodyAmp: 1.0, overtones: [(1.9, 0.35), (2.9, 0.15)],
                                       bottomHz: 650, bottomDecay: 0.040, bottomAmp: 0.85, bottomDelay: 0.005,
                                       clickHz: 0, clickAmp: 0, clickDecay: 0, bumpHz: 1100, bumpAmp: 0.65,
                                       springHz: 3800, springAmp: 0.10, upAmp: 0.4, upClick: 0,
                                       brightnessHz: 3800, level: 0.90, upLevel: 0.50)),
        SoundProfile(id: "topre", name: "Topre",
                     summary: "Muffled electrostatic-capacitive \"thup\" from a rubber dome.",
                     spec: ProfileSpec(bodyHz: 105, bodyDecay: 0.055, bodyAmp: 1.0, overtones: [(1.7, 0.3)],
                                       bottomHz: 480, bottomDecay: 0.030, bottomAmp: 0.9, bottomDelay: 0.004,
                                       clickHz: 0, clickAmp: 0, clickDecay: 0, bumpHz: 0, bumpAmp: 0,
                                       springHz: 0, springAmp: 0, upAmp: 0.55, upClick: 0,
                                       brightnessHz: 2200, level: 0.80, upLevel: 0.65)),
    ]

    public static func profile(id: String) -> SoundProfile? { all.first { $0.id == id } }
    public static var `default`: SoundProfile { all[0] }
}

/// Derives per-key-category recipes from a profile: larger keys (space, enter, backspace)
/// are stabilised and sound deeper with a rattle; modifiers are lighter.
public enum SoundDesigner {
    struct Tuning { var pitch: Double; var decay: Double; var amp: Double; var rattle: Double; var click: Double }

    static func tuning(for c: KeyCategory) -> Tuning {
        switch c {
        case .alpha:     return Tuning(pitch: 1.00, decay: 1.00, amp: 1.00, rattle: 0.00, click: 1.0)
        case .space:     return Tuning(pitch: 0.70, decay: 1.45, amp: 1.20, rattle: 0.90, click: 0.85)
        case .enter:     return Tuning(pitch: 0.80, decay: 1.30, amp: 1.12, rattle: 0.55, click: 0.9)
        case .backspace: return Tuning(pitch: 0.88, decay: 1.15, amp: 1.05, rattle: 0.35, click: 0.95)
        case .modifier:  return Tuning(pitch: 1.28, decay: 0.62, amp: 0.82, rattle: 0.00, click: 0.7)
        case .other:     return Tuning(pitch: 1.05, decay: 0.90, amp: 0.90, rattle: 0.00, click: 0.8)
        }
    }

    public static func recipe(for s: ProfileSpec, category: KeyCategory, direction: KeyDirection) -> Recipe {
        let t = tuning(for: category)
        var layers: [Layer] = []
        let body = s.bodyHz * t.pitch
        let bd = s.bodyDecay * t.decay
        let bottom = s.bottomDelay

        switch direction {
        case .down:
            layers.append(.tone(freq: body, decay: bd, amp: s.bodyAmp * t.amp, delay: bottom, glide: 0.12))
            for o in s.overtones {
                layers.append(.tone(freq: body * o.ratio, decay: bd * 0.5, amp: o.amp * t.amp, delay: bottom, glide: 0.05))
            }
            layers.append(.noise(center: s.bottomHz * t.pitch.squareRoot(), q: 0.8, decay: s.bottomDecay * t.decay,
                                 amp: s.bottomAmp * t.amp, delay: bottom))
            if s.clickAmp > 0 {
                let a = s.clickAmp * t.click
                layers.append(.noise(center: s.clickHz, q: 4, decay: s.clickDecay, amp: a, delay: 0))
                layers.append(.tone(freq: s.clickHz * 0.93, decay: s.clickDecay * 1.2, amp: a * 0.5, delay: 0, glide: 0))
            }
            if s.bumpAmp > 0 {
                layers.append(.noise(center: s.bumpHz, q: 1.5, decay: 0.006, amp: s.bumpAmp * t.click, delay: max(0, bottom - 0.003)))
            }
            if s.springAmp > 0 {
                layers.append(.tone(freq: s.springHz, decay: 0.03, amp: s.springAmp, delay: bottom + 0.001, glide: 0))
            }
            if t.rattle > 0 {
                layers.append(.noise(center: 2200, q: 2, decay: 0.05, amp: 0.28 * t.rattle, delay: bottom + 0.004))
                layers.append(.tone(freq: 1450, decay: 0.035, amp: 0.12 * t.rattle, delay: bottom + 0.006, glide: 0))
            }
            return Recipe(layers: layers, lowpassHz: s.brightnessHz, level: min(0.95, s.level * Float(min(t.amp, 1.1))),
                          duration: max(0.16, bd * 4 + bottom + 0.05))
        case .up:
            layers.append(.noise(center: s.bottomHz * 1.2, q: 1.0, decay: s.bottomDecay * 0.6 * t.decay, amp: s.upAmp, delay: 0))
            layers.append(.tone(freq: body * 1.15, decay: bd * 0.45, amp: s.upAmp * 0.6, delay: 0, glide: 0.05))
            if s.upClick > 0 {
                layers.append(.noise(center: s.clickHz * 0.9, q: 4, decay: 0.008, amp: s.upClick * t.click, delay: 0))
            }
            if s.springAmp > 0 {
                layers.append(.tone(freq: s.springHz * 1.1, decay: 0.02, amp: s.springAmp * 0.6, delay: 0.001, glide: 0))
            }
            if t.rattle > 0 {
                layers.append(.noise(center: 2000, q: 2, decay: 0.03, amp: 0.15 * t.rattle, delay: 0.002))
            }
            return Recipe(layers: layers, lowpassHz: s.brightnessHz, level: s.upLevel * Float(min(t.amp, 1.05)),
                          duration: max(0.10, bd * 2.5 + 0.03))
        }
    }
}
