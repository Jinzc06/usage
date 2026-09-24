import Foundation

enum DayKey {
    static let retention = 30

    static func string(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: calendar.startOfDay(for: date))
    }

    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key).map { calendar.startOfDay(for: $0) }
    }

    static func oldest(from today: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -(retention - 1), to: calendar.startOfDay(for: today))
            ?? calendar.startOfDay(for: today)
    }

    static func label(for day: Date, today: Date, calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: today)
        if day == today { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "昨天"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("Md")
        return formatter.string(from: day)
    }
}

struct CachedRecord: Codable, Equatable {
    var model: String
    var freshInput: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
    var total: Int
    var exactCost: String?

    init(_ record: RawRecord) {
        model = record.model
        freshInput = record.parts.freshInput
        cacheRead = record.parts.cacheRead
        cacheWrite = record.parts.cacheWrite
        output = record.parts.output
        total = record.parts.total
        exactCost = record.exactCostUSD.map(UsageMath.decimalString)
    }

    var raw: RawRecord {
        RawRecord(
            model: model,
            parts: TokenBreakdown(
                freshInput: freshInput,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                total: total
            ),
            exactCostUSD: exactCost.flatMap { Decimal(string: $0) }
        )
    }
}

struct DaySnapshot: Codable, Equatable {
    var generatedAt: Date
    var records: [String: [CachedRecord]]
    var sources: [SourceReport]
}

struct HistoryArchive: Codable, Equatable {
    var days: [String: DaySnapshot] = [:]

    static func bucket(_ records: [RawRecord], calendar: Calendar = .current) -> [String: [RawRecord]] {
        var grouped: [String: [RawRecord]] = [:]
        for record in records {
            grouped[DayKey.string(for: record.at, calendar: calendar), default: []].append(record)
        }
        return grouped
    }

    mutating func replace(day: Date, records: [String: [RawRecord]], sources: [SourceReport], at: Date, calendar: Calendar = .current) {
        let key = DayKey.string(for: day, calendar: calendar)
        days[key] = DaySnapshot(
            generatedAt: at,
            records: records.mapValues { $0.map(CachedRecord.init) },
            sources: sources
        )
    }

    mutating func merge(day: Date, source: String, records: [RawRecord], report: SourceReport, calendar: Calendar = .current) {
        let key = DayKey.string(for: day, calendar: calendar)
        var snapshot = days[key] ?? DaySnapshot(generatedAt: Date(), records: [:], sources: [])
        snapshot.records[source] = records.map(CachedRecord.init)
        snapshot.sources.removeAll { $0.name == source }
        snapshot.sources.append(report)
        snapshot.generatedAt = Date()
        days[key] = snapshot
    }

    mutating func prune(today: Date, calendar: Calendar = .current) {
        let oldest = DayKey.oldest(from: today, calendar: calendar)
        days = days.filter { key, _ in
            guard let date = DayKey.date(from: key, calendar: calendar) else { return false }
            return date >= oldest && date <= calendar.startOfDay(for: today)
        }
    }

    func snapshot(on day: Date, calendar: Calendar = .current) -> DaySnapshot? {
        days[DayKey.string(for: day, calendar: calendar)]
    }

    static func load() -> HistoryArchive {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return HistoryArchive() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(HistoryArchive.self, from: data)) ?? HistoryArchive()
    }

    func save() {
        guard let url = HistoryArchive.fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Usage/history.json")
    }
}
