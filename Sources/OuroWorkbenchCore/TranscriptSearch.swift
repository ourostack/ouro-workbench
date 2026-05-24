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

        let entriesByID = Dictionary(uniqueKeysWithValues: state.processEntries.map { ($0.id, $0) })
        let runs = state.processRuns
            .filter { $0.transcriptPath?.isEmpty == false }
            .sorted { $0.startedAt > $1.startedAt }
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
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
            return
        }
        matches.append(TranscriptSearchMatch(
            entryId: run.entryId,
            entryName: entry?.name ?? run.entryId.uuidString,
            runId: run.id,
            transcriptPath: path,
            lineNumber: lineNumber,
            line: line
        ))
    }
}

public enum TranscriptSearchLimit {
    public static let defaultMatches = 50
    public static let maximumMatches = 200

    public static func clamped(_ requested: UInt64?) -> UInt64 {
        guard let requested else {
            return UInt64(defaultMatches)
        }
        return min(max(requested, 1), UInt64(maximumMatches))
    }
}
