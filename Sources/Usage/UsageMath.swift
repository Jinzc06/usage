import Foundation

/// Token counts after deciding whether cache is already inside `input`.
struct TokenBreakdown: Equatable, Sendable {
    var freshInput: Int
    var cacheRead: Int
    var cacheWrite: Int
    var output: Int
    var total: Int

    /// When cache read + cache write fits inside `input`, those tokens are a subset and `total`
    /// is input + output. Otherwise the cache fields are additional, and `input` is the fresh part.
    static func accounting(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        reportedTotal: Int? = nil
    ) -> TokenBreakdown {
        let input = max(0, input)
        let output = max(0, output)
        let cacheRead = max(0, cacheRead)
        let cacheWrite = max(0, cacheWrite)
        let subset = cacheRead + cacheWrite <= input
        let computed = subset ? input + output : input + cacheRead + cacheWrite + output
        let total = (reportedTotal ?? 0) > 0 ? reportedTotal! : computed
        if subset {
            return TokenBreakdown(
                freshInput: input - cacheRead - cacheWrite,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                output: output,
                total: total
            )
        }
        return TokenBreakdown(
            freshInput: input,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            output: output,
            total: total
        )
    }

    var promptTokens: Int { freshInput + cacheRead + cacheWrite }
}

struct RawRecord: Equatable, Sendable {
    var model: String
    var parts: TokenBreakdown
    /// Set when the source reports a dollar amount. Estimation is skipped.
    var exactCostUSD: Decimal?
    var at: Date = .distantPast
}

struct StoredSlice: Equatable, Codable, Sendable, Identifiable {
    var name: String
    var tokens: Int
    /// Priced dollars only. Nil when none of this slice's tokens had a price or an exact cost.
    var cost: String?
    var unpricedTokens: Int

    var id: String { name }

    var costDecimal: Decimal? {
        guard let cost else { return nil }
        return Decimal(string: cost)
    }
}

enum UsageMath {
    static func canonicalID(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let last = text.split(separator: "/").last {
            text = String(last)
        }
        let suffixes = ["-xhigh", "-medium", "-minimal", "-thinking", "-high", "-max", "-low", "-fast", "-none"]
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where text.hasSuffix(suffix) {
                text.removeLast(suffix.count)
                changed = true
            }
        }
        return text
    }

    static func shortName(_ raw: String) -> String {
        let id = canonicalID(raw)
        if let version = familyVersion(id, family: "sol") { return "\(version) Sol" }
        if let version = familyVersion(id, family: "astra") { return "\(version) Astra" }
        if let version = familyVersion(id, family: "luna") { return "\(version) Luna" }
        if let version = familyVersion(id, family: "terra") { return "\(version) Terra" }
        if let grok = grokLabel(raw) { return grok }
        if let opus = opusLabel(raw) { return opus }
        switch id {
        case "k3", "kimi-k3":
            return "k3"
        case "glm-5.3":
            return "GLM-5.3"
        case "glm-5.3-flash":
            return "GLM Flash"
        case "glm-5.3-flashx":
            return "GLM FlashX"
        case "codex-auto-review":
            return "Auto Review"
        case "default":
            return "Auto"
        default:
            return raw.split(separator: "/").last.map(String.init) ?? raw
        }
    }

    static func collate(_ records: [RawRecord], includeEstimates: Bool = true) -> [StoredSlice] {
        var buckets: [String: Accumulator] = [:]
        for record in records {
            let name = shortName(record.model)
            var bucket = buckets[name] ?? Accumulator()
            if let exact = record.exactCostUSD {
                bucket.add(tokens: record.parts.total, cost: exact, unpriced: false)
            } else if includeEstimates, let price = PriceTable.price(for: record.model) {
                bucket.add(
                    tokens: record.parts.total,
                    cost: PriceTable.estimate(record.parts, price: price),
                    unpriced: false
                )
            } else {
                // Missing prices are unpriced. Turning estimates off keeps the tokens and drops the dollars.
                bucket.add(tokens: record.parts.total, cost: nil, unpriced: includeEstimates)
            }
            buckets[name] = bucket
        }
        return buckets.map { name, bucket in
            StoredSlice(
                name: name,
                tokens: bucket.tokens,
                cost: bucket.pricedTokens > 0 ? decimalString(bucket.pricedCost) : nil,
                unpricedTokens: bucket.unpricedTokens
            )
        }
        .sorted(by: sortSlices)
    }

    /// At most `count` rows. When there are more, the last row is 其他.
    static func slots(_ slices: [StoredSlice], count: Int = 8) -> [StoredSlice] {
        let sorted = slices.sorted(by: sortSlices)
        guard sorted.count > count else { return sorted }
        return cap(sorted, limit: count - 1)
    }

    /// Keep the largest token slices. The rest become 其他.
    static func cap(_ slices: [StoredSlice], limit: Int = 5) -> [StoredSlice] {
        let sorted = slices.sorted(by: sortSlices)
        guard sorted.count > limit else { return sorted }
        let head = Array(sorted.prefix(limit))
        let tail = sorted.dropFirst(limit)
        var tokens = 0
        var unpriced = 0
        var cost = Decimal(0)
        var priced = false
        for slice in tail {
            tokens += slice.tokens
            unpriced += slice.unpricedTokens
            if let value = slice.costDecimal {
                cost += value
                priced = true
            }
        }
        let other = StoredSlice(
            name: "其他",
            tokens: tokens,
            cost: priced ? decimalString(cost) : nil,
            unpricedTokens: unpriced
        )
        return head + [other]
    }

    static func totalTokens(_ slices: [StoredSlice]) -> Int {
        slices.reduce(0) { $0 + $1.tokens }
    }

    /// Nil when every token is unpriced. A real zero (priced, but free) is 0.
    static func totalCost(_ slices: [StoredSlice]) -> Decimal? {
        var sum = Decimal(0)
        var any = false
        for slice in slices {
            if let value = slice.costDecimal {
                sum += value
                any = true
            }
        }
        return any ? sum : nil
    }

    static func hasUnpriced(_ slices: [StoredSlice]) -> Bool {
        slices.contains { $0.unpricedTokens > 0 }
    }

    static func formatTokens(_ count: Int) -> String {
        let scales: [(Int, String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        for (scale, suffix) in scales where count >= scale {
            var value = Decimal(count) / Decimal(scale)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 2, .plain)
            return plain(rounded, fractionDigits: 2) + suffix
        }
        return String(count)
    }

    static func formatUSD(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        return "$" + plain(rounded, fractionDigits: 2)
    }

    static func statusTitle(tokens: Int, cost: Decimal?, loaded: Bool) -> String {
        guard loaded else { return "…" }
        guard tokens > 0 else { return "$0.00" }
        guard let cost else { return "—" }
        return formatUSD(cost)
    }

    static func decimalString(_ value: Decimal) -> String {
        plain(value, fractionDigits: 8, trim: true)
    }

    private static func sortSlices(_ lhs: StoredSlice, _ rhs: StoredSlice) -> Bool {
        if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
        return lhs.name < rhs.name
    }

    private static func grokLabel(_ raw: String) -> String? {
        let id = raw.split(separator: "/").last.map(String.init)?.lowercased() ?? raw.lowercased()
        guard let range = id.range(of: "grok") else { return nil }
        let version = id[range.upperBound...]
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        let fast = id.contains("fast")
        if version.isEmpty { return fast ? "Grok Fast" : "Grok" }
        return fast ? "Grok \(version) Fast" : "Grok \(version)"
    }

    private static func opusLabel(_ raw: String) -> String? {
        let id = raw.split(separator: "/").last.map(String.init)?.lowercased() ?? raw.lowercased()
        guard id.contains("opus") else { return nil }
        let version = id.split(separator: "-").filter { $0.contains(".") || $0.allSatisfy(\.isNumber) }
        let compact = version.joined(separator: ".")
        let effort: String
        if id.contains("-max") {
            effort = " Max"
        } else if id.contains("-xhigh") {
            effort = " XH"
        } else if id.contains("-high") {
            effort = " High"
        } else {
            effort = ""
        }
        if compact.isEmpty { return "Opus\(effort)" }
        return "Opus \(compact)\(effort)"
    }

    private static func familyVersion(_ id: String, family: String) -> String? {
        let prefix = "gpt-"
        let suffix = "-" + family
        guard id.hasPrefix(prefix), id.hasSuffix(suffix) else { return nil }
        let version = id.dropFirst(prefix.count).dropLast(suffix.count)
        return version.isEmpty ? nil : String(version)
    }

    private static func plain(_ value: Decimal, fractionDigits: Int, trim: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = trim ? 0 : fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0"
    }
}

private struct Accumulator {
    var tokens = 0
    var pricedCost = Decimal(0)
    var pricedTokens = 0
    var unpricedTokens = 0

    mutating func add(tokens: Int, cost: Decimal?, unpriced: Bool) {
        self.tokens += tokens
        if let cost {
            pricedCost += cost
            pricedTokens += tokens
        } else if unpriced {
            unpricedTokens += tokens
        }
    }
}
