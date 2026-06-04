import Foundation

/// Glanceable, derived facts about what an agent session is *doing*, distilled
/// from the agent's own structured JSONL transcript (Claude Code's
/// `~/.claude/projects/<encoded-cwd>/<session>.jsonl`; Codex's rollout files).
///
/// This is deliberately a small, redacted projection: todo progress, the
/// current step, a one-line "last tool" breadcrumb, and a token/cost summary.
/// It NEVER carries raw tool inputs/outputs — those lines in the transcript
/// embed file contents and secrets, so the reader extracts only counts, status
/// enums, and short labels. Think `GitSessionStatus`, but for activity instead
/// of branch state: a pure value the sidebar row can render at a glance.
public struct SessionActivity: Equatable, Sendable, Codable {
    /// Completed todos in the most recent todo snapshot.
    public var todoDone: Int
    /// Total todos in the most recent todo snapshot. `0` means no todo list was
    /// found in the tail (the chip then omits the progress mini).
    public var todoTotal: Int
    /// The agent's own one-line description of the step it's on right now
    /// (TodoWrite `activeForm`, e.g. "Merging PR chain"), or nil when nothing is
    /// in-progress / no list was found.
    public var activeForm: String?
    /// A short, redacted breadcrumb of the latest tool the agent invoked, e.g.
    /// "Edit OuroWorkbenchApp.swift" or "Bash". Tool *name* + at most a single
    /// path/identifier token — never the tool's full input. nil when no tool use
    /// is present in the tail.
    public var lastToolActivity: String?

    // Token usage, summed over the (bounded) tail window and de-duplicated by
    // assistant message id — see `parse` for why de-dup matters. Because the
    // window is bounded, this reflects *recent* spend, not necessarily the
    // session's lifetime total (documented on the chip's tooltip).
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    /// The model id seen most in the tail (drives pricing). nil when no
    /// assistant record carried a usable model id.
    public var model: String?

    public init(
        todoDone: Int = 0,
        todoTotal: Int = 0,
        activeForm: String? = nil,
        lastToolActivity: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        model: String? = nil
    ) {
        self.todoDone = todoDone
        self.todoTotal = todoTotal
        self.activeForm = activeForm
        self.lastToolActivity = lastToolActivity
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.model = model
    }

    /// True when nothing useful was derived — the chip should fall back to the
    /// "free" facets (health + last-activity) and skip the activity row.
    public var isEmpty: Bool {
        todoTotal == 0
            && activeForm == nil
            && lastToolActivity == nil
            && inputTokens == 0
            && outputTokens == 0
            && cacheReadTokens == 0
            && cacheCreationTokens == 0
    }

    /// Compact "3/7" todo label, or nil when there's no list.
    public var todoLabel: String? {
        guard todoTotal > 0 else { return nil }
        return "\(todoDone)/\(todoTotal)"
    }

    /// Estimated USD for the tokens in the window, using `SessionPricing`.
    /// Returns nil when the model is unknown (so the chip omits the $ rather
    /// than showing a wrong number for an unpriced model).
    public var usd: Double? {
        SessionPricing.usd(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens
        )
    }

    /// A short "$0.42" / "$1.2k"-style cost label, or nil when not priceable.
    public var usdLabel: String? {
        guard let usd, usd > 0 else { return nil }
        if usd >= 100 {
            return "$\(Int(usd.rounded()))"
        }
        if usd >= 10 {
            return String(format: "$%.0f", usd)
        }
        return String(format: "$%.2f", usd)
    }
}

/// Static, hand-maintained per-million-token pricing for the models that show
/// up in transcripts. Kept tiny and local on purpose: the chip wants a
/// directionally-correct "$" glance, not billing-grade accuracy. Cache *reads*
/// are ~0.1x input and *writes* ~1.25x input for Claude, which matters a lot
/// because cache-read dominates real sessions (often >1000x output tokens).
///
/// Matching is prefix-based on the model id (`claude-opus-4-8` →
/// "claude-opus"), so new minor/point versions price under the right family
/// without a table edit. Unknown models price to nil.
public enum SessionPricing {
    /// Per-million-token USD rates for one model family.
    public struct Rate: Sendable {
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        public var cacheWrite: Double

        public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// Family prefix → rate. Order matters only for human reading; lookup picks
    /// the longest matching prefix so "claude-opus" beats a hypothetical
    /// "claude" catch-all.
    public static let table: [(prefix: String, rate: Rate)] = [
        ("claude-opus", Rate(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)),
        ("claude-sonnet", Rate(input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75)),
        ("claude-haiku", Rate(input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1.0)),
        // Codex / GPT-family fallbacks (gpt-5 class). Directional only.
        ("gpt-5", Rate(input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25)),
    ]

    public static func rate(forModel model: String?) -> Rate? {
        guard let model = model?.lowercased() else { return nil }
        var best: (len: Int, rate: Rate)?
        for entry in table where model.hasPrefix(entry.prefix) {
            if best == nil || entry.prefix.count > best!.len {
                best = (entry.prefix.count, entry.rate)
            }
        }
        return best?.rate
    }

    public static func usd(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) -> Double? {
        guard let rate = rate(forModel: model) else { return nil }
        let perMillion = 1_000_000.0
        return Double(inputTokens) / perMillion * rate.input
            + Double(outputTokens) / perMillion * rate.output
            + Double(cacheReadTokens) / perMillion * rate.cacheRead
            + Double(cacheCreationTokens) / perMillion * rate.cacheWrite
    }
}
