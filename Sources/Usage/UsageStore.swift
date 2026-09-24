import Foundation
import Observation

struct SourceReport: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var ok: Bool
    var detail: String
    var id: String { name }
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
    private var backfill: Task<Void, Never>?
    private var recordsBySource: [String: [RawRecord]] = [:]
    private var todayBySource: [String: [RawRecord]] = [:]
    private var todaySlices: [StoredSlice] = []
    private var archive = HistoryArchive.load()
    private(set) var selectedDay = Calendar.current.startOfDay(for: Date())
    private let paths: UsagePaths

    init(paths: UsagePaths = .live()) {
        self.paths = paths
        Task { await self.loop() }
    }

    var legend: [StoredSlice] { UsageMath.slots(slices) }
    var showDayPicker = false
    var totalTokens: Int { UsageMath.totalTokens(slices) }
    var totalCost: Decimal? { UsageMath.totalCost(slices) }
    var hasUnpriced: Bool { UsageMath.hasUnpriced(slices) }

    var statusTitle: String {
        let tokens = UsageMath.totalTokens(todaySlices)
        return UsageMath.statusTitle(tokens: tokens, cost: UsageMath.totalCost(todaySlices), loaded: loaded || !todaySlices.isEmpty)
    }

    var activeSources: [SourceReport] {
        UsageSettings.sources.compactMap { name in
            guard settings.isEnabled(name) else { return nil }
            let rows = recordsBySource[name] ?? []
            guard rows.contains(where: { $0.parts.total > 0 }) else { return nil }
            return SourceReport(name: name, ok: true, detail: name)
        }
    }

    var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDay)
    }

    var dayLabel: String {
        DayKey.label(for: selectedDay, today: Date())
    }

    func canShiftDay(_ delta: Int) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let next = calendar.date(byAdding: .day, value: delta, to: selectedDay) else { return false }
        return next >= DayKey.oldest(from: today) && next <= today
    }

    func shiftDay(_ delta: Int) {
        guard canShiftDay(delta), let next = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        selectedDay = Calendar.current.startOfDay(for: next)
        showDayPicker = false
        showSelectedDay()
    }

    var recentDays: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<DayKey.retention).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    func toggleDayPicker() {
        showDayPicker.toggle()
    }

    func selectDay(_ day: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: day)
        guard day >= DayKey.oldest(from: today), day <= today else { return }
        selectedDay = day
        showDayPicker = false
        showSelectedDay()
    }

    func returnToToday() {
        showDayPicker = false
        selectedDay = Calendar.current.startOfDay(for: Date())
        showSelectedDay()
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
        todaySlices = collated(todayBySource)
        present(at: generatedAt, fromCache: showingCache)
    }

    func toggleEstimates() {
        var next = settings
        next.includeEstimates.toggle()
        settings = next
        SettingsStore.save(settings)
        guard loaded else { return }
        todaySlices = collated(todayBySource)
        present(at: generatedAt, fromCache: showingCache)
    }

    func setGlassTransparency(_ value: Double) {
        var next = settings
        next.glassTransparency = min(0.92, max(0.05, value))
        settings = next
        SettingsStore.save(settings)
    }

    func setContentTransparency(_ value: Double) {
        var next = settings
        next.contentTransparency = min(0.92, max(0.05, value))
        settings = next
        SettingsStore.save(settings)
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
        let fetched = Dictionary(uniqueKeysWithValues: names.map { name in
            if case .success(let rows) = results[name] { return (name, rows) }
            return (name, [])
        })
        if anySuccess {
            todayBySource = fetched
            todaySlices = collated(fetched)
            archive.replace(day: start, records: fetched, sources: reports, at: end)
            archive.prune(today: end)
            archive.save()
            if isViewingToday {
                recordsBySource = fetched
                sources = reports
                present(at: end, fromCache: false)
            }
            logPreview()
            scheduleBackfill()
            return
        }
        if let cached = archive.snapshot(on: start) {
            todayBySource = cached.records.mapValues { $0.map(\.raw) }
            todaySlices = collated(todayBySource)
            if isViewingToday {
                recordsBySource = todayBySource
                sources = cached.sources
                present(at: cached.generatedAt, fromCache: true)
            }
            scheduleBackfill()
            return
        }
        if isViewingToday {
            slices = []
            sources = reports
            generatedAt = nil
            loaded = true
            showingCache = false
        }
        scheduleBackfill()
    }

    private func showSelectedDay() {
        if isViewingToday {
            recordsBySource = todayBySource
            sources = archive.snapshot(on: selectedDay)?.sources ?? sources
            present(at: archive.snapshot(on: selectedDay)?.generatedAt ?? Date(), fromCache: false)
            return
        }
        guard let snapshot = archive.snapshot(on: selectedDay) else {
            recordsBySource = [:]
            slices = []
            sources = []
            generatedAt = nil
            loaded = true
            showingCache = true
            return
        }
        recordsBySource = snapshot.records.mapValues { $0.map(\.raw) }
        sources = snapshot.sources
        present(at: snapshot.generatedAt, fromCache: true)
    }

    private func collated(_ records: [String: [RawRecord]]) -> [StoredSlice] {
        var rows: [RawRecord] = []
        for name in UsageSettings.sources where settings.isEnabled(name) {
            rows.append(contentsOf: records[name] ?? [])
        }
        return UsageMath.collate(rows, includeEstimates: settings.includeEstimates)
    }

    private func scheduleBackfill() {
        guard backfill == nil else { return }
        backfill = Task { [weak self] in
            await self?.backfillHistory()
            self?.backfill = nil
        }
    }

    private func backfillHistory() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let oldest = DayKey.oldest(from: today)
        let end = Date()
        async let codex = CodexReader.load(directory: paths.codexDirectory, start: oldest, end: end)
        async let zcode = ZCodeReader.load(database: paths.zcodeDatabase, start: oldest)
        async let kimi = KimiReader.load(sessions: paths.kimiSessions, start: oldest, end: end)
        let local = await (codex, zcode, kimi)
        let named: [(String, SourceResult)] = [("Codex", local.0), ("ZCode", local.1), ("Kimi", local.2)]
        for (name, result) in named {
            guard case .success(let rows) = result else { continue }
            let report = SourceReport(name: name, ok: true, detail: name)
            for (key, records) in HistoryArchive.bucket(rows) {
                guard let day = DayKey.date(from: key), day < today else { continue }
                archive.merge(day: day, source: name, records: records, report: report)
            }
        }
        archive.prune(today: end)
        archive.save()
        if !isViewingToday { showSelectedDay() }
        var cursorDay = oldest
        while cursorDay < today {
            let key = DayKey.string(for: cursorDay)
            let hasCursor = archive.days[key]?.records["Cursor"] != nil
            if !hasCursor {
                let next = calendar.date(byAdding: .day, value: 1, to: cursorDay) ?? today
                let result = await CursorReader.load(database: paths.cursorState, start: cursorDay, end: next.addingTimeInterval(-1))
                if case .success(let rows) = result {
                    archive.merge(
                        day: cursorDay,
                        source: "Cursor",
                        records: rows,
                        report: SourceReport(name: "Cursor", ok: true, detail: "Cursor")
                    )
                    archive.save()
                    if DayKey.string(for: selectedDay) == key { showSelectedDay() }
                }
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: cursorDay) else { break }
            cursorDay = following
        }
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

