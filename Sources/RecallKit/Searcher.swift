import Foundation

enum Searcher {
    static func search(
        _ pattern: String,
        using index: SearchIndex,
        configuration: SearchConfiguration
    ) throws -> SearchReport {
        let compiledPattern = try compilePattern(pattern, configuration: configuration)
        let candidateIDs = filterDocumentIDs(
            documentIDs:
            candidateDocumentIDs(for: compiledPattern.plannerPattern, in: index, configuration: configuration),
            in: index,
            configuration: configuration
        )
        let collection = try collectMatches(
            for: compiledPattern,
            documentIDs: candidateIDs,
            in: index,
            configuration: configuration
        )

        return SearchReport(
            pattern: pattern,
            candidateCount: candidateIDs.count,
            indexedDocumentCount: index.documents.count,
            matchedFileCount: collection.matchedFileCount,
            totalMatchCount: collection.totalMatchCount,
            fileMatchCounts: collection.fileMatchCounts,
            matches: collection.matches
        )
    }

    static func naiveSearch(
        _ pattern: String,
        files: [URL],
        rootURL: URL,
        configuration: SearchConfiguration
    ) throws -> SearchReport {
        let documents = files.enumerated().map { offset, fileURL in
            IndexedDocument(id: UInt32(offset), relativePath: fileURL.relativePath(from: rootURL), byteCount: 0)
        }

        let index = SearchIndex(
            rootURL: rootURL,
            configuration: .default,
            documents: documents,
            postingLookup: [:],
            metadata: IndexMetadata(
                commitHash: nil,
                fileCount: documents.count,
                ngramCount: 0,
                configuration: .default
            )
        )

        return try search(
            pattern,
            using: index,
            configuration: SearchConfiguration(
                maxResults: configuration.maxResults,
                useLiteralPrefilter: false,
                isLiteral: configuration.isLiteral,
                caseInsensitive: configuration.caseInsensitive,
                smartCase: configuration.smartCase,
                filesOnly: configuration.filesOnly,
                countMatches: configuration.countMatches,
                maxCountPerFile: configuration.maxCountPerFile,
                quiet: configuration.quiet,
                contextLines: configuration.contextLines,
                globPattern: configuration.globPattern,
                fileType: configuration.fileType
            )
        )
    }

    private static func candidateDocumentIDs(
        for pattern: String,
        in index: SearchIndex,
        configuration: SearchConfiguration
    ) -> [UInt32] {
        RegexQueryPlanner().candidates(for: pattern, in: index, configuration: configuration)
    }

    private static func filterDocumentIDs(
        documentIDs: [UInt32],
        in index: SearchIndex,
        configuration: SearchConfiguration
    ) -> [UInt32] {
        let globMatcher: GlobMatcher?
        if let pattern = configuration.globPattern {
            globMatcher = try? GlobMatcher(pattern: pattern, allowPathSeparators: true)
        } else {
            globMatcher = nil
        }
        let normalizedFileType = configuration.fileType?.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()

        return documentIDs.filter { documentID in
            guard let document = index.document(for: documentID) else {
                return false
            }

            if let normalizedFileType, URL(fileURLWithPath: document.relativePath).pathExtension.lowercased() != normalizedFileType {
                return false
            }

            if let globMatcher, !globMatcher.matches(document.relativePath) {
                return false
            }

            return true
        }
    }

    private static func collectMatches(
        for compiledPattern: CompiledPattern,
        documentIDs: [UInt32],
        in index: SearchIndex,
        configuration: SearchConfiguration
    ) throws -> MatchCollection {
        if configuration.quiet {
            for documentID in documentIDs {
                guard let document = index.document(for: documentID) else {
                    continue
                }

                let fileURL = index.rootURL.appendingPathComponent(document.relativePath)
                if let outcome = try searchFile(
                    at: fileURL,
                    relativePath: document.relativePath,
                    compiledPattern: compiledPattern,
                    configuration: SearchConfiguration(
                        maxResults: 1,
                        useLiteralPrefilter: configuration.useLiteralPrefilter,
                        isLiteral: configuration.isLiteral,
                        caseInsensitive: configuration.caseInsensitive,
                        smartCase: configuration.smartCase,
                        filesOnly: true,
                        countMatches: true,
                        maxCountPerFile: 1,
                        quiet: true,
                        contextLines: 0,
                        globPattern: configuration.globPattern,
                        fileType: configuration.fileType
                    )
                ) {
                    return MatchCollection(
                        matches: [],
                        matchedFileCount: 1,
                        totalMatchCount: outcome.matchCount,
                        fileMatchCounts: [FileMatchCount(relativePath: document.relativePath, count: outcome.matchCount)]
                    )
                }
            }

            return MatchCollection(matches: [], matchedFileCount: 0, totalMatchCount: 0, fileMatchCounts: [])
        }

        let outcomes = try Parallel.compactMapOrdered(documentIDs) { documentID -> FileSearchOutcome? in
            guard let document = index.document(for: documentID) else {
                return nil
            }

            return try searchFile(
                at: index.rootURL.appendingPathComponent(document.relativePath),
                relativePath: document.relativePath,
                compiledPattern: compiledPattern,
                configuration: configuration
            )
        }

        let totalMatchCount = outcomes.reduce(0) { $0 + $1.matchCount }
        let fileMatchCounts = outcomes.map { FileMatchCount(relativePath: $0.relativePath, count: $0.matchCount) }
        let matches = flattenStoredMatches(outcomes.map(\ .storedMatches), limit: configuration.maxResults)

        return MatchCollection(
            matches: matches,
            matchedFileCount: outcomes.count,
            totalMatchCount: totalMatchCount,
            fileMatchCounts: fileMatchCounts
        )
    }

    private static func searchFile(
        at fileURL: URL,
        relativePath: String,
        compiledPattern: CompiledPattern,
        configuration: SearchConfiguration
    ) throws -> FileSearchOutcome? {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard !isBinary(data) else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        let layout = TextLayout(text: text)
        let matchedRanges = try matchRanges(in: text, compiledPattern: compiledPattern, configuration: configuration)

        guard !matchedRanges.isEmpty else {
            return nil
        }

        let matchCount = matchedRanges.count
        var storedMatches: [SearchResult] = []

        if configuration.countMatches || configuration.quiet {
            storedMatches = []
        } else if configuration.filesOnly {
            if let firstRange = matchedRanges.first {
                storedMatches = [layout.searchResult(for: firstRange, relativePath: relativePath, contextLines: configuration.contextLines)]
            }
        } else {
            storedMatches = matchedRanges.map {
                layout.searchResult(for: $0, relativePath: relativePath, contextLines: configuration.contextLines)
            }
        }

        return FileSearchOutcome(relativePath: relativePath, matchCount: matchCount, storedMatches: storedMatches)
    }

    private static func matchRanges(
        in text: String,
        compiledPattern: CompiledPattern,
        configuration: SearchConfiguration
    ) throws -> [Range<String.Index>] {
        if compiledPattern.isLiteral, let literal = compiledPattern.literal {
            return literalMatchRanges(
                in: text,
                literal: literal,
                caseInsensitive: compiledPattern.caseInsensitive,
                maxCount: configuration.maxCountPerFile
            )
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard compiledPattern.regex.firstMatch(in: text, range: fullRange) != nil else {
            return []
        }

        var collected: [Range<String.Index>] = []
        for match in compiledPattern.regex.matches(in: text, range: fullRange) {
            if let maxCount = configuration.maxCountPerFile, collected.count >= maxCount {
                break
            }

            guard let range = Range(match.range, in: text) else {
                continue
            }
            collected.append(range)
        }

        return collected
    }

    private static func literalMatchRanges(
        in text: String,
        literal: String,
        caseInsensitive: Bool,
        maxCount: Int?
    ) -> [Range<String.Index>] {
        guard !literal.isEmpty else {
            return []
        }

        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []

        while searchStart <= text.endIndex,
              let range = text.range(of: literal, options: options, range: searchStart..<text.endIndex) {
            ranges.append(range)

            if let maxCount, ranges.count >= maxCount {
                break
            }

            if range.lowerBound == range.upperBound {
                guard searchStart < text.endIndex else {
                    break
                }
                searchStart = text.index(after: searchStart)
            } else {
                searchStart = range.upperBound
            }
        }

        return ranges
    }

    private static func compilePattern(
        _ pattern: String,
        configuration: SearchConfiguration
    ) throws -> CompiledPattern {
        let caseInsensitive = effectiveCaseInsensitive(for: pattern, configuration: configuration)
        let regexPattern = configuration.isLiteral ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        let regex = try NSRegularExpression(
            pattern: regexPattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )

        return CompiledPattern(
            plannerPattern: caseInsensitive ? "(?i)\(regexPattern)" : regexPattern,
            regex: regex,
            isLiteral: configuration.isLiteral,
            literal: configuration.isLiteral ? pattern : nil,
            caseInsensitive: caseInsensitive
        )
    }

    private static func effectiveCaseInsensitive(
        for pattern: String,
        configuration: SearchConfiguration
    ) -> Bool {
        if configuration.caseInsensitive {
            return true
        }

        if configuration.smartCase {
            return !pattern.contains(where: \ .isUppercase)
        }

        return false
    }

    private static func flattenStoredMatches(_ groups: [[SearchResult]], limit: Int?) -> [SearchResult] {
        guard let limit else {
            return groups.flatMap { $0 }
        }

        var remaining = max(0, limit)
        var flattened: [SearchResult] = []

        for group in groups where remaining > 0 {
            let prefix = Array(group.prefix(remaining))
            flattened.append(contentsOf: prefix)
            remaining -= prefix.count
        }

        return flattened
    }

    private static func isBinary(_ data: Data) -> Bool {
        data.prefix(8_192).contains(0)
    }
}

private struct CompiledPattern {
    let plannerPattern: String
    let regex: NSRegularExpression
    let isLiteral: Bool
    let literal: String?
    let caseInsensitive: Bool
}

private struct FileSearchOutcome {
    let relativePath: String
    let matchCount: Int
    let storedMatches: [SearchResult]
}

private struct MatchCollection {
    let matches: [SearchResult]
    let matchedFileCount: Int
    let totalMatchCount: Int
    let fileMatchCounts: [FileMatchCount]
}

private struct TextLayout {
    private let text: String
    private let lineStarts: [String.Index]

    init(text: String) {
        self.text = text
        var starts = [text.startIndex]
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\n" {
                starts.append(text.index(after: index))
            }
            index = text.index(after: index)
        }
        lineStarts = starts
    }

    func searchResult(
        for range: Range<String.Index>,
        relativePath: String,
        contextLines: Int
    ) -> SearchResult {
        let lineIndex = lineIndex(containing: range.lowerBound)
        let lineNumber = lineIndex + 1
        let lineRange = lineRange(for: lineIndex)
        let contextBefore = surroundingContext(for: lineIndex, offsetRange: -contextLines..<0)
        let contextAfter = surroundingContext(for: lineIndex, offsetRange: 1..<(contextLines + 1))

        return SearchResult(
            relativePath: relativePath,
            line: lineNumber,
            column: text.distance(from: lineRange.lowerBound, to: range.lowerBound) + 1,
            excerpt: String(text[lineRange]),
            matchLength: text.distance(from: range.lowerBound, to: range.upperBound),
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
    }

    private func surroundingContext(for lineIndex: Int, offsetRange: Range<Int>) -> [SearchContextLine] {
        offsetRange.compactMap { offset in
            let candidateLineIndex = lineIndex + offset
            guard lineStarts.indices.contains(candidateLineIndex) else {
                return nil
            }

            return SearchContextLine(
                line: candidateLineIndex + 1,
                excerpt: String(text[lineRange(for: candidateLineIndex)])
            )
        }
    }

    private func lineIndex(containing index: String.Index) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count - 1

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound + 1) / 2
            if lineStarts[midpoint] <= index {
                lowerBound = midpoint
            } else {
                upperBound = midpoint - 1
            }
        }

        return lowerBound
    }

    private func lineRange(for lineIndex: Int) -> Range<String.Index> {
        let start = lineStarts[lineIndex]
        guard lineIndex + 1 < lineStarts.count else {
            return start..<text.endIndex
        }

        let nextLineStart = lineStarts[lineIndex + 1]
        return start..<text.index(before: nextLineStart)
    }
}