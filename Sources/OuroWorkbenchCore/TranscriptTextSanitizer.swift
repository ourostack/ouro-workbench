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

        return String(output)
    }

    private static func shouldKeepControlScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 || scalar == "\n" || scalar == "\t" || scalar == "\r"
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
