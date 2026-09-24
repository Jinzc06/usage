import SwiftUI

enum Palette {
    static let ink = Color(hex: 0x1B2437)
    static let track = Color.white.opacity(0.55)
    static let line = Color.white.opacity(0.7)
    static let clay = Color(hex: 0xFF4D6A)
    static let muted = Color(hex: 0x6A7894)
    static let accent = Color(hex: 0x2F6BFF)

    private static let swatches: [UInt32] = [
        0x8ECAE6, 0xC5B6E8, 0x9AD8C8, 0xE6C98A,
        0xF0B8C6, 0xA8D0F0, 0xD4C4F2, 0xC8D8B0,
    ]

    /// Names are already ordered from most tokens to least. The first slice is sky blue, the second wisteria.
    static func assignedColors(names: [String]) -> [String: Color] {
        var assigned: [String: Color] = [:]
        var index = 0
        for name in names {
            if name == "其他" {
                assigned[name] = Color(hex: 0xC5CDD6)
                continue
            }
            assigned[name] = Color(hex: swatches[index % swatches.count])
            index += 1
        }
        return assigned
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

extension View {
    /// `transparency` is 0 for a nearly solid frost and 1 for the clearest glass.
    /// The veil uses the same shape as the glass, so the rim fades with the slider.
    func usageGlass(in shape: some Shape, transparency: Double) -> some View {
        let frost = (1 - transparency) * 0.38
        let glass: Glass = transparency > 0.5 ? .clear.interactive() : .regular.interactive()
        return background { shape.fill(Color.white.opacity(frost)) }
            .glassEffect(glass, in: shape)
            .clipShape(shape)
    }

    func usageGlass(cornerRadius: CGFloat = 22, transparency: Double) -> some View {
        usageGlass(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            transparency: transparency
        )
    }
}
