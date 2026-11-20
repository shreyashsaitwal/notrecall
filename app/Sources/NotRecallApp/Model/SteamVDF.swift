import Foundation

enum SteamVDF {
    static func findBlockRange(
        named key: String,
        in text: String,
        within searchRange: Range<String.Index>? = nil
    ) -> (headerStart: String.Index, openBrace: String.Index, closeBrace: String.Index)? {
        let region = searchRange ?? (text.startIndex..<text.endIndex)
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(pattern: "\"\(escaped)\"\\s*\\{", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(region, in: text)),
              let matchRange = Range(match.range, in: text),
              let openBrace = text[matchRange].lastIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var inQuote = false
        var escapedChar = false
        var idx = openBrace
        while idx < region.upperBound {
            let ch = text[idx]
            if escapedChar {
                escapedChar = false
            } else if ch == "\\" && inQuote {
                escapedChar = true
            } else if ch == "\"" {
                inQuote.toggle()
            } else if !inQuote {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (matchRange.lowerBound, openBrace, idx)
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    static func readCompatTool(forAppID appID: String, in configVDF: URL) -> String? {
        guard let text = try? String(contentsOf: configVDF, encoding: .utf8),
              let mapping = findBlockRange(named: "CompatToolMapping", in: text),
              let appBlock = findBlockRange(named: appID, in: text, within: mapping.openBrace..<mapping.closeBrace) else {
            return nil
        }
        let body = String(text[appBlock.openBrace...appBlock.closeBrace])
        guard let regex = try? NSRegularExpression(pattern: "\"name\"\\s+\"([^\"]*)\"", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else {
            return nil
        }
        let value = String(body[range])
        return value.isEmpty ? nil : value
    }

    static func setCompatTool(forAppID appID: String, toolName: String, in configVDF: URL) throws {
        var text = try String(contentsOf: configVDF, encoding: .utf8)
        let backup = configVDF.deletingLastPathComponent().appending(path: "config.vdf.notrecall.bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? Data(text.utf8).write(to: backup, options: .atomic)
        }

        let entry = """
        \t\t\t\t\t"\(appID)"
        \t\t\t\t\t{
        \t\t\t\t\t\t"name"\t\t"\(toolName)"
        \t\t\t\t\t\t"config"\t\t""
        \t\t\t\t\t\t"priority"\t\t"250"
        \t\t\t\t\t}

        """

        if let mapping = findBlockRange(named: "CompatToolMapping", in: text) {
            if let appBlock = findBlockRange(named: appID, in: text, within: mapping.openBrace..<mapping.closeBrace) {
                let blockEnd = text.index(after: appBlock.closeBrace)
                let blockStr = String(text[appBlock.headerStart..<blockEnd])
                if let regex = try? NSRegularExpression(pattern: "\"name\"\\s+\"[^\"]*\"", options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: blockStr, range: NSRange(blockStr.startIndex..., in: blockStr)),
                   let r = Range(match.range, in: blockStr) {
                    var updatedBlock = blockStr
                    updatedBlock.replaceSubrange(r, with: "\"name\"\t\t\"\(toolName)\"")
                    text.replaceSubrange(appBlock.headerStart..<blockEnd, with: updatedBlock)
                } else {
                    text.replaceSubrange(
                        appBlock.headerStart..<blockEnd,
                        with: entry.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            } else {
                text.insert(contentsOf: entry, at: mapping.closeBrace)
            }
        } else if let steamBlock = findBlockRange(named: "Steam", in: text) {
            let section = "\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\(entry)\t\t\t\t}\n"
            text.insert(contentsOf: section, at: steamBlock.closeBrace)
        } else {
            throw NSError(
                domain: "NotRecall",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate Steam section in config.vdf"]
            )
        }

        try Data(text.utf8).write(to: configVDF, options: .atomic)
    }
}
