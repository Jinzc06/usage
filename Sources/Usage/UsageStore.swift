import Foundation
import Observation

struct SourceReport: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var ok: Bool
    var detail: String
    var id: String { name }
}

private struct CachedRecord: Codable, Equatable {
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

private struct CacheEnvelope: Codable {
    var generatedAt: Date
    var records: [String: [CachedRecord]]
    var sources: [SourceReport]
}

@MainActor
@Observable
final class UsageStore {
    private(set) var slices: [StoredSlice] = []
    private(set) var sources: [SourceReport] = []
    private(set) var loaded = false
    private(set) var refreshing = false
    private(set) var generatedAt: Date?
    private(set) var showingCache = false
    var showSettings = false
    let tokenHover = ChartHover()
    let costHover = ChartHover()
    private(set) var settings = SettingsStore.load()

    private var inflight: Task<Void, Never>?
    private var recordsBySource: [String: [RawRecord]] = [:]
    private let paths: UsagePaths

    init(paths: UsagePaths = .live()) {
        self.paths = paths
        Task { await self.loop() }
    }

    var legend: [StoredSlice] {
        slices.sorted { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            return lhs.name < rhs.name
        }
    }
    var totalTokens: Int { UsageMath.totalTokens(slices) }
    var totalCost: Decimal? { UsageMath.totalCost(slices) }
    var hasUnpriced: Bool { UsageMath.hasUnpriced(slices) }

    var statusTitle: String {
        UsageMath.statusTitle(tokens: totalTokens, cost: totalCost, loaded: loaded)
    }

    func toggleSettings() {
        showSettings.toggle()
    }

    func toggleSource(_ name: String) {
        var next = settings
        next.setEnabled(name, !next.isEnabled(name))
        settings = next
        SettingsStore.save(settings)
        guard loaded else { return }
        present(at: generatedAt, fromCache: showingCache)
    }

    func toggleEstimates() {
        var next = settings
        next.includeEstimates.toggle()
        settings = next
        SettingsStore.save(settings)
        guard loaded else { return }
        present(at: generatedAt, fromCache: showingCache)
    }

    func refresh() {
        guard inflight == nil else { return }
        inflight = Task { [weak self] in
            await self?.load()
            self?.inflight = nil
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(300))
        }
    }

    private func load() async {
        refreshing = true
        defer { refreshing = false }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Date()
        let results = await Readers.loadAll(paths: paths, start: start, end: end)
        let names = UsageSettings.sources
        var reports: [SourceReport] = []
        var anySuccess = false
        for name in names {
            switch results[name] ?? .failure("读取失败") {
            case .success:
                anySuccess = true
                reports.append(SourceReport(name: name, ok: true, detail: name))
            case .failure(let message):
                reports.append(SourceReport(name: name, ok: false, detail: "\(name) \(message)"))
            }
        }
        recordsBySource = Dictionary(uniqueKeysWithValues: names.map { name in
            if case .success(let rows) = results[name] { return (name, rows) }
            return (name, [])
        })
        if anySuccess {
            sources = reports
            present(at: end, fromCache: false)
            SnapshotCache.save(CacheEnvelope(
                generatedAt: end,
                records: recordsBySource.mapValues { $0.map(CachedRecord.init) },
                sources: reports
            ))
            logPreview()
            return
        }
        if let cached = SnapshotCache.load(on: start) {
            recordsBySource = cached.records.mapValues { $0.map(\.raw) }
            sources = cached.sources
            present(at: cached.generatedAt, fromCache: true)
            return
        }
        slices = []
        sources = reports
        generatedAt = nil
        loaded = true
        showingCache = false
    }

    private func present(at date: Date?, fromCache: Bool) {
        var records: [RawRecord] = []
        for name in UsageSettings.sources where settings.isEnabled(name) {
            records.append(contentsOf: recordsBySource[name] ?? [])
        }
        slices = UsageMath.collate(records, includeEstimates: settings.includeEstimates)
        generatedAt = date
        showingCache = fromCache
        loaded = true
    }

    private func logPreview() {
        guard ProcessInfo.processInfo.arguments.contains("--preview") else { return }
        let lines = legend.map { slice in
            let cost = slice.costDecimal.map(UsageMath.formatUSD) ?? "—"
            return "\(slice.name) \(UsageMath.formatTokens(slice.tokens)) \(cost)"
        }
        let summary = "TODAY \(statusTitle) \(lines.joined(separator: " | "))\nSOURCES \(sources.map(\.detail).joined(separator: " · "))\n"
        fputs(summary, stdout)
        fflush(stdout)
    }
}

private enum SnapshotCache {
    static func save(_ envelope: CacheEnvelope) {
        guard let url = fileURL() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func load(on dayStart: Date) -> CacheEnvelope? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(CacheEnvelope.self, from: data) else { return nil }
        guard envelope.generatedAt >= dayStart else { return nil }
        return envelope
    }

    private static func fileURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Usage/last.json")
    }
}
