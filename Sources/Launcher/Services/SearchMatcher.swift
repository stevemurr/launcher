import Foundation

enum SearchMatcher {
    struct PreparedQuery {
        fileprivate let normalized: String
        fileprivate let tokens: [String]
    }

    static func prepare(_ query: String) -> PreparedQuery {
        let normalized = normalize(query)
        return PreparedQuery(
            normalized: normalized,
            tokens: normalized.split(separator: " ").map(String.init)
        )
    }

    static func score(query: String, title: String, keywords: String = "") -> Int? {
        score(query: prepare(query), title: title, keywords: keywords)
    }

    /// Scores many records against one query without repeatedly performing
    /// locale-aware folding and tokenization for every record.
    static func score(query: PreparedQuery, title: String, keywords: String = "") -> Int? {
        guard !query.normalized.isEmpty else { return 1 }

        let normalizedTitle = normalize(title)
        let normalizedKeywords = normalize(keywords)
        let searchable = normalizedTitle + " " + normalizedKeywords

        var total = 0
        for token in query.tokens {
            guard let tokenScore = score(token: token, title: normalizedTitle, searchable: searchable) else {
                return nil
            }
            total += tokenScore
        }

        if normalizedTitle == query.normalized { total += 1_000 }
        if normalizedTitle.hasPrefix(query.normalized) { total += 500 }
        return total
    }

    private static func score(token: String, title: String, searchable: String) -> Int? {
        if title == token { return 900 }
        if title.hasPrefix(token) { return 700 - min(title.count - token.count, 100) }

        let titleWords = title.split(separator: " ")
        if titleWords.contains(where: { $0.hasPrefix(token) }) { return 600 }

        if let range = title.range(of: token) {
            return 480 - min(title.distance(from: title.startIndex, to: range.lowerBound), 100)
        }

        if searchable.contains(token) { return 320 }
        if let fuzzy = fuzzyScore(needle: token, haystack: title) { return 220 + fuzzy }
        if fuzzyScore(needle: token, haystack: searchable) != nil { return 120 }
        return nil
    }

    private static func fuzzyScore(needle: String, haystack: String) -> Int? {
        var needleIndex = needle.startIndex
        var previousMatch: String.Index?
        var score = 0

        for index in haystack.indices where needleIndex < needle.endIndex {
            if haystack[index] == needle[needleIndex] {
                if let previousMatch, haystack.index(after: previousMatch) == index {
                    score += 4
                } else {
                    score += 1
                }
                previousMatch = index
                needle.formIndex(after: &needleIndex)
            }
        }

        return needleIndex == needle.endIndex ? score : nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
