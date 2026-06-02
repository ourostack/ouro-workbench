import Foundation

/// One block in a boss/agent message. Block-level structure (headings, bullets,
/// paragraphs, blank spacing) is classified here so the view can render it
/// properly; inline marks (`**bold**`, `*italic*`, `` `code` ``, links) are left
/// in the block's `text` for the view to render via `AttributedString(markdown:)`.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(indent: Int, text: String)
    case paragraph(text: String)
    case blank
}

/// Minimal, dependency-free Markdown block parser for boss replies, which use
/// `## headings`, `-`/`*`/`•` bullets, `**bold**`, and blank-line spacing.
/// Pure + unit-tested; SwiftUI `Text` only interprets *inline* Markdown, so we
/// split blocks here and render each line's inline marks in the view.
public enum BossMessageMarkdown {
    public static func blocks(from text: String) -> [MarkdownBlock] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .map(classify)
    }

    private static func classify(_ rawLine: String) -> MarkdownBlock {
        // Measure leading spaces (for nested bullets) before trimming.
        let leadingSpaces = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .blank
        }

        // ATX heading: 1–6 '#' followed by a space.
        if trimmed.first == "#" {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes >= 1, hashes <= 6 {
                let afterHashes = trimmed.dropFirst(hashes)
                if afterHashes.first == " " {
                    return .heading(level: hashes, text: String(afterHashes).trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // Bullet: -, *, +, • or – followed by a space.
        for marker in ["- ", "* ", "+ ", "• ", "– "] {
            if trimmed.hasPrefix(marker) {
                return .bullet(indent: leadingSpaces / 2, text: String(trimmed.dropFirst(marker.count)))
            }
        }

        return .paragraph(text: trimmed)
    }
}
