import Foundation
import Observation

/// Live facts about a Hugging Face repository, fetched from the Hub (nothing hand-written).
nonisolated struct HFCard: Codable, Hashable {
    var summary: String?
    var license: String?
    var parameters: Double?      // total, from safetensors metadata
    var downloads: Int?
    var likes: Int?
    var lastModified: String?
    var gated: Bool
    var pipelineTag: String?
    var fetchedAt: Date
}

/// Hub metadata + author avatars, cached on disk (cards for a day, avatars for a week).
@Observable
final class HFMeta {
    private(set) var cards: [String: HFCard] = [:]
    private(set) var avatars: [String: URL] = [:]
    private var inFlightCards: Set<String> = []
    private var inFlightAvatars: Set<String> = []
    private var missingAvatars: Set<String> = []

    private struct Cache: Codable {
        var cards: [String: HFCard]
        var avatars: [String: URL]
        var avatarsSavedAt: Date
    }

    private static var cacheURL: URL { Paths.appSupport.appendingPathComponent("hf-meta-cache.json") }

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cache = try? JSONDecoder.iso.decode(Cache.self, from: data) {
            cards = cache.cards.filter { Date().timeIntervalSince($0.value.fetchedAt) < 86_400 }
            if Date().timeIntervalSince(cache.avatarsSavedAt) < 7 * 86_400 { avatars = cache.avatars }
        }
    }

    private func persist() {
        let cache = Cache(cards: cards, avatars: avatars, avatarsSavedAt: Date())
        Paths.ensure(Paths.appSupport)
        if let data = try? JSONEncoder.iso.encode(cache) { try? data.write(to: Self.cacheURL, options: .atomic) }
    }

    // MARK: Avatars

    func avatar(for owner: String) -> URL? {
        if let url = avatars[owner] { return url }
        guard !inFlightAvatars.contains(owner), !missingAvatars.contains(owner) else { return nil }
        inFlightAvatars.insert(owner)
        Task {
            defer { inFlightAvatars.remove(owner) }
            for kind in ["organizations", "users"] {
                let url = HFClient.base.appendingPathComponent("api/\(kind)/\(owner)/avatar")
                if let data = try? await HFClient.get(url),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let string = json["avatarUrl"] as? String, let avatar = URL(string: string) {
                    avatars[owner] = avatar
                    persist()
                    return
                }
            }
            missingAvatars.insert(owner)
        }
        return nil
    }

    // MARK: Cards

    func card(for repo: String) -> HFCard? {
        if let card = cards[repo] { return card }
        guard !inFlightCards.contains(repo) else { return nil }
        inFlightCards.insert(repo)
        Task {
            defer { inFlightCards.remove(repo) }
            if let card = await Self.fetchCard(repo) {
                cards[repo] = card
                persist()
            }
        }
        return nil
    }

    nonisolated private static func fetchCard(_ repo: String) async -> HFCard? {
        var components = URLComponents(url: HFClient.base.appendingPathComponent("api/models/\(repo)"), resolvingAgainstBaseURL: false)!
        components.queryItems = ["safetensors", "cardData", "downloads", "likes", "lastModified", "gated", "pipeline_tag"]
            .map { URLQueryItem(name: "expand[]", value: $0) }
        guard let data = try? await HFClient.get(components.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let card = json["cardData"] as? [String: Any]
        let gatedValue = json["gated"]
        return HFCard(
            summary: await fetchSummary(repo),
            license: card?["license"] as? String,
            parameters: ((json["safetensors"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue,
            downloads: (json["downloads"] as? NSNumber)?.intValue,
            likes: (json["likes"] as? NSNumber)?.intValue,
            lastModified: json["lastModified"] as? String,
            gated: (gatedValue as? Bool) ?? (gatedValue is String),
            pipelineTag: json["pipeline_tag"] as? String,
            fetchedAt: Date())
    }

    /// Model-card description: raw README first; for gated repos (raw file needs accepted access)
    /// the public model page's rendered card, then its meta description.
    nonisolated private static func fetchSummary(_ repo: String) async -> String? {
        if let data = try? await HFClient.get(URL(string: "https://huggingface.co/\(repo)/raw/main/README.md")!) {
            let text = String(decoding: data, as: UTF8.self)
            if !text.hasPrefix("Access to model"), let summary = summarize(text) { return summary }
        }
        guard let data = try? await HFClient.get(URL(string: "https://huggingface.co/\(repo)")!) else { return nil }
        let page = String(decoding: data, as: UTF8.self)
        if let start = page.range(of: "model-card-content") {
            var card = String(page[start.upperBound...].prefix(60_000))
            card = card.replacingOccurrences(of: "<(pre|svg|script|style|table)[\\s\\S]*?</\\1>", with: "\n\n", options: .regularExpression)
            card = card.replacingOccurrences(of: "<h[1-6][\\s\\S]*?</h[1-6]>", with: "\n\n", options: .regularExpression)
            card = card.replacingOccurrences(of: "</(p|li|div|ul|ol|blockquote)>|<br\\s*/?>", with: "\n\n", options: .regularExpression)
            card = card.replacingOccurrences(of: "\n[ \t]+", with: "\n", options: .regularExpression)
            card = card.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            if let summary = summarize(card.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")) {
                return summary
            }
        }
        if let match = page.range(of: "<meta name=\"description\" content=\"[^\"]+\"", options: .regularExpression) {
            let tag = page[match]
            if let q = tag.range(of: "content=\"") {
                return String(tag[q.upperBound...].dropLast()).replacingOccurrences(of: "&#39;", with: "'")
            }
        }
        return nil
    }

    /// First real prose paragraph of a model card: no front matter, badges, HTML, tables or headings.
    nonisolated static func summarize(_ markdown: String) -> String? {
        var text = markdown
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<h[1-6][\\s\\S]*?</h[1-6]>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "&#?[a-zA-Z0-9]+;", with: " ", options: .regularExpression)
        for paragraph in text.components(separatedBy: "\n\n") {
            let lines = paragraph.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") && !$0.hasPrefix(">") }
            var p = lines.joined(separator: " ")
            guard p.filter({ $0 == "|" }).count < 2 else { continue }   // link bars like "GitHub | Blog | Discord"
            p = p.replacingOccurrences(of: "\\*\\*|__|`", with: "", options: .regularExpression)
            p = p.replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression)
            p = p.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            // Leading emoji and bullets go; a rank like "#1" stays.
            while let first = p.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first),
                  !(first == "#" && p.dropFirst().first?.isNumber == true) { p.removeFirst() }
            let letters = p.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard p.count >= 80, letters > p.count / 2 else { continue }
            if p.count > 320, let cut = p.prefix(320).lastIndex(of: " ") { p = String(p[..<cut]) + "…" }
            return p
        }
        return nil
    }
}

extension JSONDecoder {
    nonisolated static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    nonisolated static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

nonisolated enum ParamFormat {
    static func billions(_ total: Double?) -> String? {
        guard let total, total > 0 else { return nil }
        let b = total / 1e9
        return b >= 10 ? String(format: "%.0fB", b) : String(format: "%.1fB", b)
    }
}
