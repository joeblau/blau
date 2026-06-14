import Foundation

/// Sublime-style fuzzy scoring for the file finder.
///
/// `score(query:candidate:)` answers two questions in one pass: *is* the query a
/// (case-insensitive) subsequence of the candidate, and *how good* is that match.
/// `nil` means "no match"; any `Int` means "match", and higher is better. The
/// algorithm is greedy and allocation-light — it walks each string once over a
/// `UnicodeScalar` view and keeps a handful of running counters — so it stays
/// cheap enough to run against tens of thousands of paths on every keystroke.
enum FuzzyMatcher {
    // Bonus/penalty weights. These are relative knobs, not absolutes — what
    // matters is their ordering: a basename hit should beat a directory hit, a
    // boundary hit should beat a mid-word hit, and consecutive runs should beat
    // scattered letters.
    private static let consecutiveBonus = 15      // each char that continues a run
    private static let boundaryBonus = 30         // char right after a separator / camelCase edge
    private static let startBonus = 35            // char at index 0 of the candidate
    private static let basenameBonus = 20         // char that lands in the basename (after last slash)
    private static let leadingPenalty = -3        // mild cost per unmatched char before the first hit
    private static let gapPenalty = -2            // mild cost per unmatched char inside a gap

    /// Returns a match score, or `nil` when `query` is not a case-insensitive
    /// subsequence of `candidate`. An empty query matches everything with score `0`.
    static func score(query: String, candidate: String) -> Int? {
        // Empty query is the "no filter" case — every candidate matches equally.
        if query.isEmpty { return 0 }

        // Work over Unicode scalars to avoid per-character String allocations.
        // Lowercasing the scalars gives case-insensitive comparison without
        // building lowercased copies of the whole strings.
        let queryScalars = Array(query.unicodeScalars)
        let candidateScalars = Array(candidate.unicodeScalars)
        if candidateScalars.count < queryScalars.count { return nil }

        // The basename starts one past the last path separator. Matches at or
        // after this index earn the basename bonus, biasing results toward the
        // filename the user is most likely typing.
        let basenameStart = lastSeparatorIndex(in: candidateScalars).map { $0 + 1 } ?? 0

        var score = 0
        var queryIndex = 0
        var previousMatchIndex = -1      // candidate index of the last matched char, -1 if none yet
        var queryScalar = lowercased(queryScalars[0])

        for candidateIndex in candidateScalars.indices {
            guard lowercased(candidateScalars[candidateIndex]) == queryScalar else { continue }

            // --- positional bonuses ---
            // The first character of the basename is the strongest anchor — it's
            // almost always what the user is typing — so it earns the full start
            // bonus. A match at index 0 that is actually a leading directory char
            // only gets the lesser boundary bonus, so a directory whose name
            // prefixes the query can't outrank the basename the user wants.
            if candidateIndex == basenameStart {
                score += startBonus
            } else if candidateIndex == 0 || isBoundary(candidateScalars, at: candidateIndex) {
                score += boundaryBonus
            }
            if candidateIndex >= basenameStart {
                score += basenameBonus
            }

            // --- run / gap accounting ---
            if previousMatchIndex == candidateIndex - 1 {
                // Directly adjacent to the previous match: reward the run.
                score += consecutiveBonus
            } else if previousMatchIndex >= 0 {
                // A gap inside the match — penalize mildly, proportional to size.
                score += gapPenalty * (candidateIndex - previousMatchIndex - 1)
            } else {
                // Unmatched run before the very first hit — penalize mildly.
                score += leadingPenalty * candidateIndex
            }

            previousMatchIndex = candidateIndex
            queryIndex += 1
            if queryIndex == queryScalars.count {
                return score   // consumed the whole query: it's a subsequence
            }
            queryScalar = lowercased(queryScalars[queryIndex])
        }

        // Ran out of candidate before matching every query char.
        return nil
    }

    // MARK: - Helpers

    /// Index of the last path-like separator, or `nil` if there is none.
    private static func lastSeparatorIndex(in scalars: [UnicodeScalar]) -> Int? {
        var index = scalars.count - 1
        while index >= 0 {
            if scalars[index] == "/" { return index }
            index -= 1
        }
        return nil
    }

    /// A candidate position is a "boundary" if the preceding scalar is a
    /// separator (slash, underscore, hyphen, dot, space) or if it sits on a
    /// camelCase edge (a lowercase/digit scalar immediately followed by an
    /// uppercase one). Boundaries are where humans visually anchor, so matching
    /// there is worth more.
    private static func isBoundary(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = scalars[index - 1]
        switch previous {
        case "/", "_", "-", ".", " ":
            return true
        default:
            // camelCase edge: previous is lower/number, current is upper.
            return !isUppercase(previous) && isUppercase(scalars[index])
        }
    }

    /// ASCII-fast lowercasing. Known limitation: only A–Z is case-folded, so a
    /// query and candidate that differ only by the case of a non-ASCII letter
    /// (e.g. "é" vs "É") won't match. Filenames in this codebase are ASCII, so
    /// this is an accepted trade-off for the per-keystroke hot path.
    private static func lowercased(_ scalar: UnicodeScalar) -> UnicodeScalar {
        let value = scalar.value
        if value >= 65 && value <= 90 {   // 'A'...'Z'
            return UnicodeScalar(value + 32)!
        }
        return scalar
    }

    private static func isUppercase(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return value >= 65 && value <= 90  // 'A'...'Z'
    }
}
