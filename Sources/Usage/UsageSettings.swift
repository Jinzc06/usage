import Foundation

struct UsageSettings: Equatable, Sendable {
    var cursor = true
    var codex = true
    var zcode = true
    var kimi = true
    var includeEstimates = true

    static let sources = ["Cursor", "Codex", "ZCode", "Kimi"]

    func isEnabled(_ name: String) -> Bool {
        switch name {
        case "Cursor": cursor
        case "Codex": codex
        case "ZCode": zcode
        case "Kimi": kimi
        default: true
        }
    }

    var everySourceOff: Bool {
        Self.sources.allSatisfy { !isEnabled($0) }
    }

    mutating func setEnabled(_ name: String, _ enabled: Bool) {
        switch name {
        case "Cursor": cursor = enabled
        case "Codex": codex = enabled
        case "ZCode": zcode = enabled
        case "Kimi": kimi = enabled
        default: break
        }
    }

    static func kind(of name: String) -> String {
        name == "Cursor" ? "账单实扣" : "标价估算"
    }
}

extension UsageSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case cursor, codex, zcode, kimi, includeEstimates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent(Bool.self, forKey: .cursor) ?? true
        codex = try container.decodeIfPresent(Bool.self, forKey: .codex) ?? true
        zcode = try container.decodeIfPresent(Bool.self, forKey: .zcode) ?? true
        kimi = try container.decodeIfPresent(Bool.self, forKey: .kimi) ?? true
        includeEstimates = try container.decodeIfPresent(Bool.self, forKey: .includeEstimates) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(codex, forKey: .codex)
        try container.encode(zcode, forKey: .zcode)
        try container.encode(kimi, forKey: .kimi)
        try container.encode(includeEstimates, forKey: .includeEstimates)
    }
}

enum SettingsStore {
    static func load() -> UsageSettings {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return UsageSettings() }
        return (try? JSONDecoder().decode(UsageSettings.self, from: data)) ?? UsageSettings()
    }

    static func save(_ settings: UsageSettings) {
        guard let url = fileURL(), let data = try? JSONEncoder().encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Usage/settings.json")
    }
}
