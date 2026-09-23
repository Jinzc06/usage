import SwiftUI

enum Palette {
    static let paper = Color(hex: 0xF4F8FF)
    static let card = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x1B2437)
    static let track = Color(hex: 0xE3EDF8)
    static let line = Color(hex: 0xD5E4F5)
    static let clay = Color(hex: 0xFF4D6A)
    static let muted = Color(hex: 0x6A7894)
    static let accent = Color(hex: 0x2F6BFF)

    private static let swatches: [UInt32] = [
        0x2F6BFF, 0xFF8A1F, 0x14C8A8, 0xFFC400, 0xFF4F8B,
        0x3EC6FF, 0x7C5CFF, 0xFF6B6B, 0x7ED957, 0xF06BD8,
    ]

    /// Stable for a given set of names. Collisions walk to the next free swatch so two models in view don't share a color.
    static func assignedColors(names: [String]) -> [String: Color] {
        var used = Set<Int>()
        var assigned: [String: Color] = [:]
        for name in names.sorted() {
            if name == "其他" {
                assigned[name] = Color(hex: 0xB7C3D6)
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
