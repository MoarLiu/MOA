import Foundation

enum MoaTomlEditor {
    struct LineContext {
        let text: String
        let contentRange: Range<String.Index>
        let nextLineStart: String.Index
        let isStructural: Bool
    }

    private enum MultilineString {
        case basic
        case literal
    }

    struct Entry {
        let table: String
        let key: String
        let value: String
        let lineRange: Range<String.Index>

        var path: String {
            table.isEmpty ? key : "\(table).\(key)"
        }

        var lineText: String {
            "\(key) = \(value)"
        }
    }

    static func entries(in text: String) -> [Entry] {
        var entries: [Entry] = []
        var currentTable = ""

        for context in lineContexts(in: text) where context.isStructural {
            let line = context.text
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let tableName = tableName(from: trimmed) {
                currentTable = tableName
            } else if let keyValue = keyValue(from: line) {
                entries.append(Entry(table: currentTable, key: keyValue.key, value: keyValue.value, lineRange: context.contentRange))
            }
        }

        return entries
    }

    static func lineContexts(in text: String) -> [LineContext] {
        var contexts: [LineContext] = []
        var multiline: MultilineString?
        var lineStart = text.startIndex

        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(of: "\n")
            let lineEnd = newline ?? text.endIndex
            let nextLineStart = newline.map { text.index(after: $0) } ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            let startedInsideMultiline = multiline != nil
            let sawMultilineDelimiter = updateMultilineState(for: line, state: &multiline)
            contexts.append(LineContext(
                text: line,
                contentRange: lineStart..<lineEnd,
                nextLineStart: nextLineStart,
                isStructural: !startedInsideMultiline && multiline == nil && !sawMultilineDelimiter
            ))
            lineStart = nextLineStart
        }

        if text.isEmpty || text.hasSuffix("\n") {
            contexts.append(LineContext(
                text: "",
                contentRange: text.endIndex..<text.endIndex,
                nextLineStart: text.endIndex,
                isStructural: multiline == nil
            ))
        }
        return contexts
    }

    private static func updateMultilineState(for line: String, state: inout MultilineString?) -> Bool {
        let characters = Array(line)
        var index = 0
        var quote: Character?
        var escaped = false
        var sawDelimiter = false

        func hasDelimiter(_ delimiter: [Character], at offset: Int) -> Bool {
            offset + delimiter.count <= characters.count
                && Array(characters[offset..<(offset + delimiter.count)]) == delimiter
        }

        while index < characters.count {
            if let multiline = state {
                let delimiter: [Character] = multiline == .basic ? ["\"", "\"", "\""] : ["'", "'", "'"]
                if hasDelimiter(delimiter, at: index), multiline == .literal || !isEscaped(characters, at: index) {
                    state = nil
                    sawDelimiter = true
                    index += 3
                } else {
                    index += 1
                }
                continue
            }

            if let currentQuote = quote {
                let character = characters[index]
                if currentQuote == "'" {
                    if character == "'" {
                        quote = nil
                    }
                } else if character == "\"" && !escaped {
                    quote = nil
                }
                if currentQuote == "\"" && character == "\\" && !escaped {
                    escaped = true
                } else {
                    escaped = false
                }
                index += 1
                continue
            }

            if hasDelimiter(["\"", "\"", "\""], at: index) {
                state = .basic
                sawDelimiter = true
                index += 3
            } else if hasDelimiter(["'", "'", "'"], at: index) {
                state = .literal
                sawDelimiter = true
                index += 3
            } else if characters[index] == "#" {
                break
            } else if characters[index] == "\"" || characters[index] == "'" {
                quote = characters[index]
                escaped = false
                index += 1
            } else {
                index += 1
            }
        }
        return sawDelimiter
    }

    private static func isEscaped(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else {
            return false
        }
        var cursor = index - 1
        var backslashes = 0
        while characters[cursor] == "\\" {
            backslashes += 1
            guard cursor > 0 else {
                break
            }
            cursor -= 1
        }
        return backslashes % 2 == 1
    }

    static func tableName(from line: String) -> String? {
        let trimmed = trimInlineComment(from: line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              trimmed.hasSuffix("]"),
              !trimmed.hasPrefix("[["),
              !trimmed.hasSuffix("]]")
        else {
            return nil
        }

        let start = trimmed.index(after: trimmed.startIndex)
        let end = trimmed.index(before: trimmed.endIndex)
        let name = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func keyValue(from line: String) -> (key: String, value: String)? {
        let scanner = Scanner(string: line)
        scanner.charactersToBeSkipped = nil

        _ = scanner.scanCharacters(from: .whitespacesAndNewlines)
        guard let rawKey = scanner.scanUpToString("=") else {
            return nil
        }

        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, scanner.scanString("=") != nil else {
            return nil
        }

        let remainder = String(line[scanner.currentIndex...])
        let value = trimInlineComment(from: remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }

        return (key, value)
    }

    static func trimInlineComment(from value: String) -> String {
        var quote: Character?
        var previousWasEscape = false

        for index in value.indices {
            let character = value[index]

            if let currentQuote = quote {
                if currentQuote == "'" {
                    if character == "'" {
                        quote = nil
                    }
                    continue
                }

                if character == currentQuote && !previousWasEscape {
                    quote = nil
                    previousWasEscape = false
                    continue
                }
                if character == "\\" && !previousWasEscape {
                    previousWasEscape = true
                } else {
                    previousWasEscape = false
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                previousWasEscape = false
                continue
            }

            if character == "#" {
                return String(value[..<index])
            }
        }

        return value
    }

    static func collapseBlankLines(_ text: String) -> String {
        let contexts = lineContexts(in: text)
        guard let firstContent = contexts.firstIndex(where: { !isStructuralBlank($0) }),
              let lastContent = contexts.lastIndex(where: { !isStructuralBlank($0) })
        else {
            return ""
        }

        var output: [String] = []
        var previousWasStructuralBlank = false
        for context in contexts[firstContent...lastContent] {
            let isBlank = isStructuralBlank(context)
            if isBlank && previousWasStructuralBlank {
                continue
            }
            output.append(context.text)
            previousWasStructuralBlank = isBlank
        }
        return output.joined(separator: "\n")
    }

    static func collapseBlankLinesBeforeTables(_ text: String) -> String {
        let output = collapseBlankLines(text)

        var lines: [String] = []
        for context in lineContexts(in: output) {
            let trimmed = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if context.isStructural,
               tableName(from: trimmed) != nil,
               let previousLine = lines.last,
               !previousLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
            }
            lines.append(context.text)
        }
        return collapseBlankLines(lines.joined(separator: "\n"))
    }

    private static func isStructuralBlank(_ context: LineContext) -> Bool {
        context.isStructural && context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func quotedString(_ value: String) -> String {
        "\"\(escapedStringContent(value))\""
    }

    static func escapedStringContent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func unquoteString(_ raw: String) -> String {
        var value = raw
        if value.count >= 2 {
            let quote = value.first
            value.removeFirst()
            value.removeLast()
            guard quote == "\"" else {
                return value
            }
        }

        var output = ""
        var isEscaped = false
        for character in value {
            if isEscaped {
                switch character {
                case "b":
                    output.append("\u{08}")
                case "t":
                    output.append("\t")
                case "n":
                    output.append("\n")
                case "f":
                    output.append("\u{0C}")
                case "r":
                    output.append("\r")
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                default:
                    output.append("\\")
                    output.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                output.append(character)
            }
        }

        if isEscaped {
            output.append("\\")
        }
        return output
    }
}
