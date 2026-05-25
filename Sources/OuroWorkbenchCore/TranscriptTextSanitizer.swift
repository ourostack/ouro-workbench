import Foundation

public enum TranscriptTextSanitizer {
    public static func sanitized(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = scalars.startIndex

        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard scalar.value == 0x1B else {
                if shouldKeepControlScalar(scalar) {
                    output.append(scalar)
                }
                index += 1
                continue
            }

            index = indexAfterEscapeSequence(in: scalars, startingAt: index)
        }

        return postProcess(String(output))
    }

    private static func shouldKeepControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" || scalar == "\r"
    }

    private static func postProcess(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return collapseBlankLines(omitTerminalRepaintFragments(in: normalized))
    }

    private static func omitTerminalRepaintFragments(in text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var chunk: [String] = []
        var fragmentCount = 0

        func flushChunk() {
            guard !chunk.isEmpty else {
                return
            }
            if fragmentCount >= 5 {
                output.append("[terminal screen repaint omitted]")
            } else {
                output.append(contentsOf: chunk)
            }
            chunk.removeAll()
            fragmentCount = 0
        }

        for line in lines {
            if line.isEmpty || isLikelyRepaintFragment(line) {
                chunk.append(line)
                if isLikelyRepaintFragment(line) {
                    fragmentCount += 1
                }
            } else {
                flushChunk()
                output.append(line)
            }
        }
        flushChunk()

        return output.joined(separator: "\n")
    }

    private static func isLikelyRepaintFragment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 2 else {
            return false
        }
        return true
    }

    private static func collapseBlankLines(_ text: String) -> String {
        var output = ""
        var blankCount = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                blankCount += 1
                if blankCount <= 2 {
                    output.unicodeScalars.append(scalar)
                }
            } else {
                blankCount = 0
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func indexAfterEscapeSequence(
        in scalars: [Unicode.Scalar],
        startingAt escapeIndex: Int
    ) -> Int {
        var index = escapeIndex + 1
        guard index < scalars.endIndex else {
            return index
        }

        switch scalars[index] {
        case "[":
            index += 1
            while index < scalars.endIndex {
                let value = scalars[index].value
                index += 1
                if (0x40...0x7E).contains(value) {
                    break
                }
            }
            return index
        case "]":
            index += 1
            while index < scalars.endIndex {
                if scalars[index].value == 0x07 {
                    return index + 1
                }
                if scalars[index].value == 0x1B,
                   index + 1 < scalars.endIndex,
                   scalars[index + 1] == "\\" {
                    return index + 2
                }
                index += 1
            }
            return index
        default:
            return index + 1
        }
    }
}
