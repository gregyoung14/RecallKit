import Foundation

public struct IndexConfiguration: Codable, Sendable, Hashable {
    public var maxNGramLength: Int
    public var maxCoveringNGrams: Int
    public var includeHiddenFiles: Bool
    public var followSymlinks: Bool
    public var respectIgnoreFiles: Bool
    public var ignoreFileNames: [String]
    public var maxFileSize: Int
    public var skippedDirectoryNames: Set<String>

    private enum CodingKeys: String, CodingKey {
        case maxNGramLength
        case maxCoveringNGrams
        case includeHiddenFiles
        case followSymlinks
        case respectIgnoreFiles
        case ignoreFileNames
        case maxFileSize
        case skippedDirectoryNames
    }

    public init(
        maxNGramLength: Int = 128,
        maxCoveringNGrams: Int = .max,
        includeHiddenFiles: Bool = false,
        followSymlinks: Bool = false,
        respectIgnoreFiles: Bool = true,
        ignoreFileNames: [String] = [".gitignore", ".frgignore"],
        maxFileSize: Int = 10 * 1024 * 1024,
        skippedDirectoryNames: Set<String> = [".build", ".frg", ".git", ".swiftpm", "DerivedData"]
    ) {
        self.maxNGramLength = max(2, maxNGramLength)
        self.maxCoveringNGrams = max(1, maxCoveringNGrams)
        self.includeHiddenFiles = includeHiddenFiles
        self.followSymlinks = followSymlinks
        self.respectIgnoreFiles = respectIgnoreFiles
        self.ignoreFileNames = ignoreFileNames
        self.maxFileSize = max(1, maxFileSize)
        self.skippedDirectoryNames = skippedDirectoryNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxNGramLength = max(2, try container.decodeIfPresent(Int.self, forKey: .maxNGramLength) ?? 128)
        maxCoveringNGrams = max(1, try container.decodeIfPresent(Int.self, forKey: .maxCoveringNGrams) ?? .max)
        includeHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .includeHiddenFiles) ?? false
        followSymlinks = try container.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? false
        respectIgnoreFiles = try container.decodeIfPresent(Bool.self, forKey: .respectIgnoreFiles) ?? true
        ignoreFileNames = try container.decodeIfPresent([String].self, forKey: .ignoreFileNames) ?? [".gitignore", ".frgignore"]
        maxFileSize = max(1, try container.decodeIfPresent(Int.self, forKey: .maxFileSize) ?? 10 * 1024 * 1024)
        skippedDirectoryNames = try container.decodeIfPresent(Set<String>.self, forKey: .skippedDirectoryNames)
            ?? [".build", ".frg", ".git", ".swiftpm", "DerivedData"]
    }

    public static let `default` = IndexConfiguration()
}

public struct SearchConfiguration: Codable, Sendable, Hashable {
    public var maxResults: Int?
    public var useLiteralPrefilter: Bool

    public var isLiteral: Bool
    public var caseInsensitive: Bool
    public var smartCase: Bool
    public var filesOnly: Bool
    public var countMatches: Bool
    public var maxCountPerFile: Int?
    public var quiet: Bool
    public var contextLines: Int
    public var globPattern: String?
    public var fileType: String?

    private enum CodingKeys: String, CodingKey {
        case maxResults
        case useLiteralPrefilter
        case isLiteral
        case caseInsensitive
        case smartCase
        case filesOnly
        case countMatches
        case maxCountPerFile
        case quiet
        case contextLines
        case globPattern
        case fileType
    }

    public init(
        maxResults: Int? = 200,
        useLiteralPrefilter: Bool = true,
        isLiteral: Bool = false,
        caseInsensitive: Bool = false,
        smartCase: Bool = false,
        filesOnly: Bool = false,
        countMatches: Bool = false,
        maxCountPerFile: Int? = nil,
        quiet: Bool = false,
        contextLines: Int = 0,
        globPattern: String? = nil,
        fileType: String? = nil
    ) {
        self.maxResults = maxResults
        self.useLiteralPrefilter = useLiteralPrefilter
        self.isLiteral = isLiteral
        self.caseInsensitive = caseInsensitive
        self.smartCase = smartCase
        self.filesOnly = filesOnly
        self.countMatches = countMatches
        self.maxCountPerFile = maxCountPerFile
        self.quiet = quiet
        self.contextLines = max(0, contextLines)
        self.globPattern = globPattern
        self.fileType = fileType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxResults = try container.decodeIfPresent(Int.self, forKey: .maxResults)
        useLiteralPrefilter = try container.decodeIfPresent(Bool.self, forKey: .useLiteralPrefilter) ?? true
        isLiteral = try container.decodeIfPresent(Bool.self, forKey: .isLiteral) ?? false
        caseInsensitive = try container.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        smartCase = try container.decodeIfPresent(Bool.self, forKey: .smartCase) ?? false
        filesOnly = try container.decodeIfPresent(Bool.self, forKey: .filesOnly) ?? false
        countMatches = try container.decodeIfPresent(Bool.self, forKey: .countMatches) ?? false
        maxCountPerFile = try container.decodeIfPresent(Int.self, forKey: .maxCountPerFile)
        quiet = try container.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
        contextLines = max(0, try container.decodeIfPresent(Int.self, forKey: .contextLines) ?? 0)
        globPattern = try container.decodeIfPresent(String.self, forKey: .globPattern)
        fileType = try container.decodeIfPresent(String.self, forKey: .fileType)
    }

    public static let `default` = SearchConfiguration()
}

public struct SearchContextLine: Codable, Sendable, Hashable {
    public let line: Int
    public let excerpt: String

    public init(line: Int, excerpt: String) {
        self.line = line
        self.excerpt = excerpt
    }
}

public struct FileMatchCount: Codable, Sendable, Hashable {
    public let relativePath: String
    public let count: Int

    public init(relativePath: String, count: Int) {
        self.relativePath = relativePath
        self.count = count
    }
}

public struct IndexedDocument: Codable, Sendable, Hashable {
    public let id: UInt32
    public let relativePath: String
    public let byteCount: Int
    public let modifiedAtEpochSeconds: UInt64

    public init(
        id: UInt32,
        relativePath: String,
        byteCount: Int,
        modifiedAtEpochSeconds: UInt64 = 0
    ) {
        self.id = id
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.modifiedAtEpochSeconds = modifiedAtEpochSeconds
    }
}

public struct IndexMetadata: Codable, Sendable, Hashable {
    public static let currentVersion = 2

    public let version: Int
    public let commitHash: String?
    public let fileCount: Int
    public let ngramCount: Int
    public let timestamp: UInt64
    public let configuration: IndexConfiguration
    public let overlayFileCount: Int
    public let overlayNGramCount: Int
    public let tombstoneCount: Int

    public init(
        version: Int = IndexMetadata.currentVersion,
        commitHash: String?,
        fileCount: Int,
        ngramCount: Int,
        timestamp: UInt64 = IndexMetadata.timestampNow(),
        configuration: IndexConfiguration,
        overlayFileCount: Int = 0,
        overlayNGramCount: Int = 0,
        tombstoneCount: Int = 0
    ) {
        self.version = version
        self.commitHash = commitHash
        self.fileCount = fileCount
        self.ngramCount = ngramCount
        self.timestamp = timestamp
        self.configuration = configuration
        self.overlayFileCount = overlayFileCount
        self.overlayNGramCount = overlayNGramCount
        self.tombstoneCount = tombstoneCount
    }

    public static func timestampNow() -> UInt64 {
        UInt64(Date().timeIntervalSince1970)
    }
}

public struct IndexStatus: Sendable, Hashable {
    public let rootURL: URL
    public let indexDirectoryURL: URL
    public let generationID: String
    public let metadata: IndexMetadata

    public init(rootURL: URL, indexDirectoryURL: URL, generationID: String, metadata: IndexMetadata) {
        self.rootURL = rootURL
        self.indexDirectoryURL = indexDirectoryURL
        self.generationID = generationID
        self.metadata = metadata
    }

    public var ageSeconds: UInt64 {
        IndexMetadata.timestampNow().saturatingSubtracting(metadata.timestamp)
    }
}

public struct SearchResult: Codable, Sendable, Hashable {
    public let relativePath: String
    public let line: Int
    public let column: Int
    public let excerpt: String
    public let matchLength: Int
    public let contextBefore: [SearchContextLine]
    public let contextAfter: [SearchContextLine]

    public init(
        relativePath: String,
        line: Int,
        column: Int,
        excerpt: String,
        matchLength: Int = 0,
        contextBefore: [SearchContextLine] = [],
        contextAfter: [SearchContextLine] = []
    ) {
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.excerpt = excerpt
        self.matchLength = max(0, matchLength)
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

public struct SearchReport: Codable, Sendable, Hashable {
    public let pattern: String
    public let candidateCount: Int
    public let indexedDocumentCount: Int
    public let matchedFileCount: Int
    public let totalMatchCount: Int
    public let fileMatchCounts: [FileMatchCount]
    public let matches: [SearchResult]

    public init(
        pattern: String,
        candidateCount: Int,
        indexedDocumentCount: Int,
        matchedFileCount: Int,
        totalMatchCount: Int,
        fileMatchCounts: [FileMatchCount],
        matches: [SearchResult]
    ) {
        self.pattern = pattern
        self.candidateCount = candidateCount
        self.indexedDocumentCount = indexedDocumentCount
        self.matchedFileCount = matchedFileCount
        self.totalMatchCount = totalMatchCount
        self.fileMatchCounts = fileMatchCounts
        self.matches = matches
    }
}

public struct BenchmarkSnapshot: Codable, Sendable, Hashable {
    public let fileCount: Int
    public let buildMilliseconds: Double
    public let indexedSearchMilliseconds: Double
    public let naiveSearchMilliseconds: Double
    public let candidateCount: Int
    public let indexedMatchCount: Int
    public let naiveMatchCount: Int

    public init(
        fileCount: Int,
        buildMilliseconds: Double,
        indexedSearchMilliseconds: Double,
        naiveSearchMilliseconds: Double,
        candidateCount: Int,
        indexedMatchCount: Int,
        naiveMatchCount: Int
    ) {
        self.fileCount = fileCount
        self.buildMilliseconds = buildMilliseconds
        self.indexedSearchMilliseconds = indexedSearchMilliseconds
        self.naiveSearchMilliseconds = naiveSearchMilliseconds
        self.candidateCount = candidateCount
        self.indexedMatchCount = indexedMatchCount
        self.naiveMatchCount = naiveMatchCount
    }

    public var speedup: Double? {
        guard indexedSearchMilliseconds > 0 else { return nil }
        return naiveSearchMilliseconds / indexedSearchMilliseconds
    }
}

struct PostingBucket: Codable, Sendable, Hashable {
    let hash: UInt64
    let documents: [UInt32]
}