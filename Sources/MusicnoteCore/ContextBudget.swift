import Foundation

/// Context window policy for a conversation.
///
/// C = min(1,000,000, actual window). Compaction triggers before the next send
/// would reach min(0.95 × C, C − R), where R reserves room for output and
/// protocol overhead. 95% of 1M is 950,000 tokens — a trigger, not a target.
public struct ContextBudget: Sendable {
    public static let userCeiling = 1_000_000
    public var actualWindow: Int
    public var reserve: Int

    public init(actualWindow: Int, reserve: Int = 32_000) { self.actualWindow = actualWindow; self.reserve = reserve }

    public var capacity: Int { min(Self.userCeiling, actualWindow) }
    public var trigger: Int { min(Int(Double(capacity) * 0.95), capacity - reserve) }

    public func shouldCompact(projectedTokens: Int) -> Bool { projectedTokens >= trigger }

    /// Rough token estimate when the provider cannot report usage: CJK ≈ 1 token/char, Latin ≈ 4 chars/token.
    public static func estimateTokens(_ text: String) -> Int {
        var cjk = 0, other = 0
        for s in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(s.value) || (0x3000...0x30FF).contains(s.value) { cjk += 1 } else { other += 1 }
        }
        return cjk + other / 4 + 1
    }
}
