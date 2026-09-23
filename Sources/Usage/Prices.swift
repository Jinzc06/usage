import Foundation

/// USD per 1,000,000 tokens. Figures were read from the cited pages on `verifiedAt`.
struct ModelPrice: Equatable, Sendable {
    var input: Decimal
    var cachedInput: Decimal
    var cacheWrite: Decimal
    var output: Decimal
    var longInput: Decimal?
    var longCachedInput: Decimal?
    var longCacheWrite: Decimal?
    var longOutput: Decimal?
    /// Use the long-context rates when the request's prompt is strictly above this size.
    var longContextAbove: Int?
    var source: String
    var verifiedAt: String
}

enum PriceTable {
    private static let verified = "2026-09-23"

    static let prices: [String: ModelPrice] = [
        "gpt-6-sol": ModelPrice(
            input: Decimal(string: "2")!,
            cachedInput: Decimal(string: "0.20")!,
            cacheWrite: Decimal(string: "2.50")!,
            output: Decimal(string: "10")!,
            longInput: Decimal(string: "4")!,
            longCachedInput: Decimal(string: "0.40")!,
            longCacheWrite: Decimal(string: "5")!,
            longOutput: Decimal(string: "15")!,
            longContextAbove: 272_000,
            source: "https://developers.openai.com/api/docs/models/gpt-6-sol",
            verifiedAt: verified
        ),
        "gpt-6-astra": ModelPrice(
            input: Decimal(string: "10")!,
            cachedInput: Decimal(string: "1")!,
            cacheWrite: Decimal(string: "12.50")!,
            output: Decimal(string: "50")!,
            longInput: Decimal(string: "20")!,
            longCachedInput: Decimal(string: "2")!,
            longCacheWrite: Decimal(string: "25")!,
            longOutput: Decimal(string: "75")!,
            longContextAbove: 272_000,
            source: "https://developers.openai.com/api/docs/models/gpt-6-astra",
            verifiedAt: verified
        ),
        "gpt-5.6-sol": ModelPrice(
            input: Decimal(string: "4")!,
            cachedInput: Decimal(string: "0.40")!,
            cacheWrite: Decimal(string: "5")!,
            output: Decimal(string: "20")!,
            longInput: Decimal(string: "8")!,
            longCachedInput: Decimal(string: "0.80")!,
            longCacheWrite: Decimal(string: "10")!,
            longOutput: Decimal(string: "30")!,
            longContextAbove: 272_000,
            source: "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
            verifiedAt: verified
        ),
        // Z.AI lists cached-input storage as free and has no separate cache-write token price.
        // Creation tokens are priced as fresh input.
        "glm-5.3": glm(
            input: "1.4",
            cached: "0.26",
            output: "4.4"
        ),
        "glm-5.3-flash": glm(
            input: "0.15",
            cached: "0.03",
            output: "0.50"
        ),
        "glm-5.3-flashx": glm(
            input: "0.37",
            cached: "0.075",
            output: "1.25"
        ),
        // 5-minute cache write is the default TTL. The 1-hour write tier is $6 and is not used
        // because the local log does not record which tier a write landed in.
        "k3": ModelPrice(
            input: Decimal(string: "3")!,
            cachedInput: Decimal(string: "0.30")!,
            cacheWrite: Decimal(string: "3")!,
            output: Decimal(string: "15")!,
            source: "https://platform.kimi.ai/docs/pricing/chat-k3",
            verifiedAt: verified
        ),
    ]

    static func price(for model: String) -> ModelPrice? {
        let id = UsageMath.canonicalID(model)
        if let price = prices[id] { return price }
        if id == "kimi-k3" { return prices["k3"] }
        return nil
    }

    static func estimate(_ parts: TokenBreakdown, price: ModelPrice) -> Decimal {
        let long = price.longContextAbove.map { parts.promptTokens > $0 } ?? false
        let input = long ? (price.longInput ?? price.input) : price.input
        let cached = long ? (price.longCachedInput ?? price.cachedInput) : price.cachedInput
        let write = long ? (price.longCacheWrite ?? price.cacheWrite) : price.cacheWrite
        let output = long ? (price.longOutput ?? price.output) : price.output
        let million = Decimal(1_000_000)
        return Decimal(parts.freshInput) * input / million
            + Decimal(parts.cacheRead) * cached / million
            + Decimal(parts.cacheWrite) * write / million
            + Decimal(parts.output) * output / million
    }

    private static func glm(input: String, cached: String, output: String) -> ModelPrice {
        let inputRate = Decimal(string: input)!
        return ModelPrice(
            input: inputRate,
            cachedInput: Decimal(string: cached)!,
            cacheWrite: inputRate,
            output: Decimal(string: output)!,
            source: "https://docs.z.ai/guides/overview/pricing",
            verifiedAt: verified
        )
    }
}
