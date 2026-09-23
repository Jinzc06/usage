import SwiftUI

enum Palette {
    static let paper = Color(hex: 0xF3EFE6)
    static let card = Color(hex: 0xFBF7F0)
    static let ink = Color(hex: 0x241F1C)
    static let track = Color(hex: 0xE3DCD0)
    static let line = Color(hex: 0xE4DCCD)
    static let clay = Color(hex: 0xC46B3A)
    static let muted = Color(hex: 0x7A726A)

    private static let swatches: [UInt32] = [0x2F6F5E, 0xC46B3A, 0xC6A15B, 0x3E5C76, 0x8C4A55]

    /// Stable for a given set of names. Collisions walk to the next free swatch so two models in view don't share a color.
    static func assignedColors(names: [String]) -> [String: Color] {
        var used = Set<Int>()
        var assigned: [String: Color] = [:]
        for name in names.sorted() {
            if name == "其他" {
                assigned[name] = Color(hex: 0x8A8175)
                continue
            }
            var index = Int(hash(name) % UInt64(swatches.count))
            if used.count < swatches.count {
                var steps = 0
                while used.contains(index), steps < swatches.count {
                    index = (index + 1) % swatches.count
                    steps += 1
                }
            }
            used.insert(index)
            assigned[name] = Color(hex: swatches[index])
        }
        return assigned
    }

    private static func hash(_ name: String) -> UInt64 {
        var value: UInt64 = 5381
        for byte in name.utf8 {
            value = value &* 33 &+ UInt64(byte)
        }
        return value
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
