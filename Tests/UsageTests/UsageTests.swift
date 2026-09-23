import Foundation
import SwiftUI
import Testing

@testable import Usage

@Test func cacheInsideInputIsNotAddedTwice() {
    let parts = TokenBreakdown.accounting(
        input: 100,
        output: 10,
        cacheRead: 80,
        cacheWrite: 5,
        reportedTotal: 110
    )
    #expect(parts.freshInput == 15)
    #expect(parts.cacheRead == 80)
    #expect(parts.cacheWrite == 5)
    #expect(parts.total == 110)
}

@Test func separateCacheFieldsAreSummed() {
    let parts = TokenBreakdown.accounting(
        input: 10,
        output: 3,
        cacheRead: 50,
        cacheWrite: 5
    )
    #expect(parts.freshInput == 10)
    #expect(parts.total == 68)
}

@Test func zeroReportedTotalFallsBackToComponents() {
    let parts = TokenBreakdown.accounting(
        input: 40,
        output: 2,
        cacheRead: 30,
        cacheWrite: 0,
        reportedTotal: 0
    )
    #expect(parts.freshInput == 10)
    #expect(parts.total == 42)
}

@Test func tokenFormatUsesThousandsMillionsBillions() {
    #expect(UsageMath.formatTokens(47_598_800) == "47.60M")
    #expect(UsageMath.formatTokens(10_000) == "10.00K")
    #expect(UsageMath.formatTokens(999) == "999")
    #expect(UsageMath.formatTokens(1_500_000_000) == "1.50B")
    #expect(UsageMath.formatTokens(0) == "0")
}

@Test func donutHoverHitsTheSegmentUnderThePointer() {
    let slices = [
        DonutSlice(name: "A", color: .blue, fraction: 0.5, label: "1"),
        DonutSlice(name: "B", color: .orange, fraction: 0.5, label: "1"),
    ]
    #expect(DonutHit.hit(slices, at: CGPoint(x: 62, y: 8), side: 124, lineWidth: 16) == "A")
    #expect(DonutHit.hit(slices, at: CGPoint(x: 8, y: 62), side: 124, lineWidth: 16) == "B")
    #expect(DonutHit.hit(slices, at: CGPoint(x: 62, y: 62), side: 124, lineWidth: 16) == nil)
}

@Test func shortNames() {
    #expect(UsageMath.shortName("gpt-5.6-sol-medium") == "5.6 Sol")
    #expect(UsageMath.shortName("gpt-6-sol") == "6 Sol")
    #expect(UsageMath.shortName("gpt-6-astra") == "6 Astra")
    #expect(UsageMath.shortName("kimi-code/k3") == "k3")
    #expect(UsageMath.shortName("GLM-5.3-Flash") == "GLM Flash")
    #expect(UsageMath.shortName("grok-4.7-xhigh") == "Grok 4.7")
    #expect(UsageMath.shortName("grok-4.7-xhigh-fast") == "Grok 4.7 Fast")
    #expect(UsageMath.shortName("cursor-grok-4.6-high") == "Grok 4.6")
    #expect(UsageMath.shortName("claude-opus-5-5-max") == "Opus 5.5 Max")
    #expect(UsageMath.shortName("claude-opus-5-5-high") == "Opus 5.5 High")
}

@Test func capMergesTheTail() {
    let slices = (1...6).map {
        StoredSlice(name: "m\($0)", tokens: $0, cost: "\($0)", unpricedTokens: 0)
    }
    let capped = UsageMath.cap(slices)
    #expect(capped.map(\.name) == ["m6", "m5", "m4", "m3", "m2", "其他"])
    #expect(capped.last?.tokens == 1)
}

@Test func missingPriceIsNotZero() {
    let slices = UsageMath.collate([
        RawRecord(
            model: "codex-auto-review",
            parts: TokenBreakdown.accounting(input: 200_000, output: 0, cacheRead: 0, cacheWrite: 0),
            exactCostUSD: nil
        ),
        RawRecord(
            model: "gpt-6-sol",
            parts: TokenBreakdown.accounting(input: 200_000, output: 0, cacheRead: 0, cacheWrite: 0),
            exactCostUSD: nil
        ),
    ])
    let unknown = slices.first { $0.name == "Auto Review" }
    #expect(unknown?.tokens == 200_000)
    #expect(unknown?.cost == nil)
    #expect(unknown?.unpricedTokens == 200_000)
    #expect(UsageMath.totalCost(slices) == Decimal(string: "0.4"))
    #expect(UsageMath.hasUnpriced(slices))
    #expect(UsageMath.statusTitle(tokens: 400_000, cost: UsageMath.totalCost(slices), loaded: true) == "$0.40")
    #expect(UsageMath.statusTitle(tokens: 1_000_000, cost: nil, loaded: true) == "—")
    #expect(UsageMath.statusTitle(tokens: 0, cost: nil, loaded: true) == "$0.00")
}

@Test func excludingEstimatesKeepsTokensAndDropsEstimatedDollars() {
    let parts = TokenBreakdown.accounting(input: 200_000, output: 0, cacheRead: 0, cacheWrite: 0)
    let slices = UsageMath.collate([
        RawRecord(model: "gpt-6-sol", parts: parts, exactCostUSD: nil),
        RawRecord(model: "gpt-6-sol", parts: parts, exactCostUSD: Decimal(string: "1.25")),
    ], includeEstimates: false)
    #expect(slices.first?.tokens == 400_000)
    #expect(slices.first?.costDecimal == Decimal(string: "1.25"))
    #expect(slices.first?.unpricedTokens == 0)
    #expect(!UsageMath.hasUnpriced(slices))
}

@Test func settingsRoundTripKeepsSourceSwitches() throws {
    var settings = UsageSettings()
    settings.setEnabled("ZCode", false)
    settings.includeEstimates = false
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(UsageSettings.self, from: data)
    #expect(!decoded.isEnabled("ZCode"))
    #expect(decoded.isEnabled("Cursor"))
    #expect(!decoded.includeEstimates)
    #expect(decoded.everySourceOff == false)
}

@Test func exactCostSkipsThePriceTable() {
    let slices = UsageMath.collate([
        RawRecord(
            model: "gpt-6-sol",
            parts: TokenBreakdown.accounting(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0),
            exactCostUSD: Decimal(string: "1.25")
        )
    ])
    #expect(slices.first?.costDecimal == Decimal(string: "1.25"))
}

@Test func publishedRates() {
    let fresh = TokenBreakdown.accounting(input: 250_000, output: 0, cacheRead: 0, cacheWrite: 0)
    #expect(PriceTable.estimate(fresh, price: PriceTable.price(for: "gpt-6-sol")!) == Decimal(string: "0.5"))
    #expect(PriceTable.estimate(fresh, price: PriceTable.price(for: "gpt-6-astra")!) == Decimal(string: "2.5"))
    #expect(PriceTable.estimate(fresh, price: PriceTable.price(for: "gpt-5.6-sol")!) == Decimal(string: "1"))
    #expect(PriceTable.estimate(fresh, price: PriceTable.price(for: "GLM-5.3")!) == Decimal(string: "0.35"))
    #expect(PriceTable.estimate(fresh, price: PriceTable.price(for: "kimi-code/k3")!) == Decimal(string: "0.75"))

    let cached = TokenBreakdown.accounting(input: 250_000, output: 0, cacheRead: 250_000, cacheWrite: 0)
    #expect(PriceTable.estimate(cached, price: PriceTable.price(for: "gpt-6-sol")!) == Decimal(string: "0.05"))

    let long = TokenBreakdown.accounting(input: 300_000, output: 0, cacheRead: 0, cacheWrite: 0)
    #expect(PriceTable.estimate(long, price: PriceTable.price(for: "gpt-6-sol")!) == Decimal(string: "1.2"))

    let output = TokenBreakdown.accounting(input: 0, output: 1_000_000, cacheRead: 0, cacheWrite: 0)
    #expect(PriceTable.estimate(output, price: PriceTable.price(for: "glm-5.3-flashx")!) == Decimal(string: "1.25"))
}

@Test func cursorPayloadParsesStringTokensAndCents() {
    let json = """
    {"aggregations":[{"modelIntent":"gpt-5.6-sol-medium","inputTokens":"100","outputTokens":"20","cacheReadTokens":"400","cacheWriteTokens":"5","totalCents":250.5}]}
    """.data(using: .utf8)!
    let records = CursorReader.parse(json)
    #expect(records.count == 1)
    #expect(records[0].parts.total == 525)
    #expect(records[0].exactCostUSD == Decimal(string: "2.505"))
    #expect(UsageMath.shortName(records[0].model) == "5.6 Sol")
}

@Test func codexRolloutKeepsOnlyTodaysRecords() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "usage-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rollout = root.appending(path: "rollout.jsonl")
    let start = Date(timeIntervalSince1970: 1_790_092_800)
    let body = """
    {"type":"turn_context","payload":{"turn_id":"t1","model":"gpt-6-sol"}}
    {"timestamp":"2026-09-23T02:00:00.000Z","type":"token_usage_record","payload":{"turn_id":"t1","usage":{"input_tokens":1000,"cached_input_tokens":800,"cache_write_input_tokens":0,"output_tokens":50,"total_tokens":1050}}}
    {"timestamp":"2026-09-22T02:00:00.000Z","type":"token_usage_record","payload":{"turn_id":"t1","usage":{"input_tokens":500,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10,"total_tokens":510}}}
    """
    try body.write(to: rollout, atomically: true, encoding: .utf8)
    let database = try SQLiteDB.create(root.appending(path: "state_5.sqlite").path)
    try database.execute("CREATE TABLE threads (rollout_path TEXT, model TEXT, updated_at_ms INTEGER)")
    let stamp = Int(start.timeIntervalSince1970 * 1000)
    try database.execute("INSERT INTO threads VALUES ('\(rollout.path)', 'fallback', \(stamp))")
    database.close()

    let result = CodexReader.loadSync(directory: root, start: start, end: start.addingTimeInterval(86_400))
    guard case .success(let records) = result else {
        Issue.record("expected success")
        return
    }
    #expect(records.count == 1)
    #expect(records[0].model == "gpt-6-sol")
    #expect(records[0].parts.freshInput == 200)
    #expect(records[0].parts.total == 1050)
}

@Test func kimiFileReadsUsageRecords() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "usage-kimi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let start = Date(timeIntervalSince1970: 1_790_092_800)
    let stamp = Int(start.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    let file = root.appending(path: "wire.jsonl")
    let line = """
    {"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":4,"inputCacheRead":100,"inputCacheCreation":6},"time":\(stamp)}
    """
    try line.write(to: file, atomically: true, encoding: .utf8)
    let result = KimiReader.loadSync(sessions: root, start: start, end: start.addingTimeInterval(86_400))
    guard case .success(let records) = result else {
        Issue.record("expected success")
        return
    }
    #expect(records.count == 1)
    #expect(records[0].parts.total == 120)
    #expect(records[0].parts.freshInput == 10)
    let slices = UsageMath.collate(records)
    #expect(slices.first?.name == "k3")
    #expect(slices.first?.cost != nil)
}
