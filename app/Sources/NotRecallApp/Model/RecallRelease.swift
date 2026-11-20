import Foundation

struct RecallReleaseInfo: Identifiable, Equatable, Sendable {
    let tagName: String
    let version: String
    let title: String
    let publishedAt: Date?
    let releasePageURL: URL
    let dmgName: String
    let dmgURL: URL
    let dmgSizeBytes: Int64?
    let dmgSHA256: String?
    let sha256AssetURL: URL?
    let whatsNewMarkdown: String
    let minimumMacOS: String?

    var id: String { tagName }

    var formattedSize: String? {
        guard let bytes = dmgSizeBytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let repoSlug = "AsherJN/recall"

    static let pinnedDefault: RecallReleaseInfo = {
        let tag = "v1.6.6"
        let base = "https://github.com/\(repoSlug)/releases"
        return RecallReleaseInfo(
            tagName: tag,
            version: "1.6.6",
            title: "Recall 1.6.6",
            publishedAt: ISO8601DateFormatter().date(from: "2026-11-20T00:50:32Z"),
            releasePageURL: URL(string: "\(base)/tag/\(tag)")!,
            dmgName: "Recall-1.6.6.dmg",
            dmgURL: URL(string: "\(base)/download/\(tag)/Recall-1.6.6.dmg")!,
            dmgSizeBytes: 245_727_901,
            dmgSHA256: "d98f4230ff1605178e6c64fe12829c3960c361f638eec42dfb60d4e08cf7e5e2",
            sha256AssetURL: URL(string: "\(base)/download/\(tag)/Recall-1.6.6.dmg.sha256")!,
            whatsNewMarkdown: "Recall 1.6.6 — Highlights improvements and MP4 saving fixes.",
            minimumMacOS: "26.5"
        )
    }()
}

enum RecallVersion {
    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = normalized(lhs).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = normalized(rhs).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }
}

enum RecallReleaseError: LocalizedError {
    case invalidResponse
    case missingDMGAsset(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Unexpected response from GitHub Releases API."
        case .missingDMGAsset(let tag):
            return "Recall release \(tag) does not contain a .dmg download asset."
        case .httpStatus(let code):
            return "GitHub returned HTTP \(code) while checking for Recall updates."
        }
    }
}

enum RecallReleaseService {
    static let latestReleaseEndpoint = URL(string: "https://api.github.com/repos/\(RecallReleaseInfo.repoSlug)/releases/latest")!

    private struct GitHubReleasePayload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let published_at: String?
        let assets: [GitHubAssetPayload]
    }

    private struct GitHubAssetPayload: Decodable {
        let name: String
        let size: Int64?
        let digest: String?
        let browser_download_url: String
    }

    static func fetchLatestRelease() async throws -> RecallReleaseInfo {
        var request = URLRequest(url: latestReleaseEndpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotRecall", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecallReleaseError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RecallReleaseError.httpStatus(http.statusCode)
        }

        let payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        guard let dmgAsset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dmgURL = URL(string: dmgAsset.browser_download_url),
              let pageURL = URL(string: payload.html_url) else {
            throw RecallReleaseError.missingDMGAsset(payload.tag_name)
        }

        let shaAsset = payload.assets.first(where: { $0.name.lowercased() == dmgAsset.name.lowercased() + ".sha256" })
        let shaAssetURL = shaAsset.flatMap { URL(string: $0.browser_download_url) }

        var sha256: String?
        if let digest = dmgAsset.digest, digest.lowercased().hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        } else if let sidecarURL = shaAssetURL {
            sha256 = try? await fetchSidecarSHA256(from: sidecarURL)
        }

        let rawBody = payload.body ?? ""
        let minMacOS = parseMinimumMacOS(from: rawBody)
        let cleanedNotes = cleanReleaseNotes(rawBody)
        let publishedAt = payload.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        let version = RecallVersion.normalized(payload.tag_name)

        return RecallReleaseInfo(
            tagName: payload.tag_name,
            version: version,
            title: (payload.name?.isEmpty == false ? payload.name! : "Recall \(version)"),
            publishedAt: publishedAt,
            releasePageURL: pageURL,
            dmgName: dmgAsset.name,
            dmgURL: dmgURL,
            dmgSizeBytes: dmgAsset.size,
            dmgSHA256: sha256,
            sha256AssetURL: shaAssetURL,
            whatsNewMarkdown: cleanedNotes,
            minimumMacOS: minMacOS
        )
    }

    private static func fetchSidecarSHA256(from url: URL) async throws -> String? {
        var req = URLRequest(url: url)
        req.setValue("NotRecall", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .lowercased()
        guard let hash = token, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return hash
    }

    static func parseMinimumMacOS(from body: String) -> String? {
        let pattern = #"minimum-macos:\s*([0-9]+(?:\.[0-9]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let r = Range(match.range(at: 1), in: body) else {
            return nil
        }
        return String(body[r])
    }

    private static func stripDelimitedBlocks(in text: String, open: String, close: String) -> String {
        var result = text
        while let start = result.range(of: open, options: .caseInsensitive),
              let end = result.range(of: close, options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result
    }

    static func cleanReleaseNotes(_ body: String) -> String {
        var cleaned = stripDelimitedBlocks(in: body, open: "<!" + "--", close: "--" + ">")
        cleaned = stripDelimitedBlocks(in: cleaned, open: "<" + "details>", close: "</" + "details>")
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "See the GitHub release page for full release notes." : trimmed
    }
}
