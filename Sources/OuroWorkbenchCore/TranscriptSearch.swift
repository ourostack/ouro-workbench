import Foundation

public struct TranscriptSearchMatch: Codable, Equatable, Identifiable, Sendable {
    public var entryId: UUID
    public var entryName: String
    public var runId: UUID
    public var transcriptPath: String
    public var lineNumber: Int
    public var line: String

    public init(
        entryId: UUID,
        entryName: String,
        runId: UUID,
        transcriptPath: String,
        lineNumber: Int,
        line: String
    ) {
        self.entryId = entryId
        self.entryName = entryName
        self.runId = runId
        self.transcriptPath = transcriptPath
        self.lineNumber = lineNumber
        self.line = line
    }

    public var id: String {
        "\(runId.uuidString):\(lineNumber)"
    }
}

public struct TranscriptSearcher {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func search(
        query: String,
        state: WorkspaceState,
        maxMatches: Int = 50
    ) -> [TranscriptSearchMatch] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, maxMatches > 0 else {
            return []
        }

        // Collision-safe (keep first): a duplicate entry id in a malformed
        // state file must not trap and crash the MCP server's search tool.
        let entriesByID = Dictionary(
            state.processEntries.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let runs = state.processRuns
            .filter { $0.transcriptPath?.isEmpty == false }
            .sorted(by: ProcessRun.isMoreRecent)
        var matches: [TranscriptSearchMatch] = []

        for run in runs {
            guard let transcriptPath = run.transcriptPath,
                  fileManager.fileExists(atPath: transcriptPath)
            else {
                continue
            }

            let entry = entriesByID[run.entryId]
            let remaining = maxMatches - matches.count
            let runMatches = searchTranscriptFile(
                path: transcriptPath,
                query: query,
                entry: entry,
                run: run,
                maxMatches: remaining
            )
            matches.append(contentsOf: runMatches)
            if matches.count >= maxMatches {
                return matches
            }
        }

        return matches
    }

    private func searchTranscriptFile(
        path: String,
        query: String,
        entry: ProcessEntry?,
        run: ProcessRun,
        maxMatches: Int
    ) -> [TranscriptSearchMatch] {
        guard maxMatches > 0,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else {
            return []
        }
        defer {
            try? handle.close()
        }

        var matches: [TranscriptSearchMatch] = []
        var buffer = Data()
        var lineNumber = 0

        while matches.count < maxMatches {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            drainCompleteLines(
                from: &buffer,
                query: query,
                entry: entry,
                run: run,
                path: path,
                lineNumber: &lineNumber,
                matches: &matches,
                maxMatches: maxMatches
            )
            if matches.count < maxMatches, buffer.count > TranscriptSearchLimit.maximumBufferedLineBytes {
                lineNumber += 1
                appendMatchIfNeeded(
                    data: buffer,
                    query: query,
                    entry: entry,
                    run: run,
                    path: path,
                    lineNumber: lineNumber,
                    matches: &matches
                )
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if matches.count < maxMatches, !buffer.isEmpty {
            lineNumber += 1
            appendMatchIfNeeded(
                data: buffer,
                query: query,
                entry: entry,
                run: run,
                path: path,
                lineNumber: lineNumber,
                matches: &matches
            )
        }

        return matches
    }

    private func drainCompleteLines(
        from buffer: inout Data,
        query: String,
        entry: ProcessEntry?,
        run: ProcessRun,
        path: String,
        lineNumber: inout Int,
        matches: inout [TranscriptSearchMatch],
        maxMatches: Int
    ) {
        while matches.count < maxMatches,
              let newlineRange = buffer.firstRange(of: Data([0x0a])) {
            let lineData = buffer[..<newlineRange.lowerBound]
            buffer.removeSubrange(..<newlineRange.upperBound)
            lineNumber += 1
            appendMatchIfNeeded(
                data: lineData,
                query: query,
                entry: entry,
                run: run,
                path: path,
                lineNumber: lineNumber,
                matches: &matches
            )
        }
    }

    private func appendMatchIfNeeded(
        data: Data,
        query: String,
        entry: ProcessEntry?,
        run: ProcessRun,
        path: String,
        lineNumber: Int,
        matches: inout [TranscriptSearchMatch]
    ) {
        let line = TranscriptTextSanitizer.sanitized(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .newlines)
        guard line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
            return
        }
        matches.append(TranscriptSearchMatch(
            entryId: run.entryId,
            entryName: entry?.name ?? run.entryId.uuidString,
            runId: run.id,
            transcriptPath: path,
            lineNumber: lineNumber,
            line: clippedLine(line, query: query)
        ))
    }

    private func clippedLine(_ line: String, query: String) -> String {
        guard line.count > TranscriptSearchLimit.maximumLineCharacters else {
            return line
        }
        guard let range = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return "\(line.prefix(TranscriptSearchLimit.maximumLineCharacters))..."
        }

        let beforeBudget = TranscriptSearchLimit.maximumLineCharacters / 2
        let availableBefore = line.distance(from: line.startIndex, to: range.lowerBound)
        let lower = line.index(range.lowerBound, offsetBy: -min(beforeBudget, availableBefore))
        let usedThroughMatch = line.distance(from: lower, to: range.upperBound)
        let afterBudget = max(TranscriptSearchLimit.maximumLineCharacters - usedThroughMatch, 0)
        let availableAfter = line.distance(from: range.upperBound, to: line.endIndex)
        let upper = line.index(range.upperBound, offsetBy: min(afterBudget, availableAfter))
        let prefix = lower == line.startIndex ? "" : "..."
        let suffix = upper == line.endIndex ? "" : "..."
        return "\(prefix)\(line[lower..<upper])\(suffix)"
    }
}

public enum TranscriptSearchLimit {
    public static let defaultMatches = 50
    public static let maximumMatches = 200
    public static let maximumBufferedLineBytes = 1_048_576
    public static let maximumLineCharacters = 500

    public static func clamped(_ requested: UInt64?) -> UInt64 {
        guard let requested else {
            return UInt64(defaultMatches)
        }
        return min(max(requested, 1), UInt64(maximumMatches))
    }
}
