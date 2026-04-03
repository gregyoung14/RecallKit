import Foundation

public struct MemoryBudget: Codable, Sendable, Hashable {
    public var maxResidentChunkBytes: Int
    public var maxMappedIndexBytes: Int
    public var maxCachedChunkCount: Int
    public var maxChunkBytes: Int

    public init(
        maxResidentChunkBytes: Int = 32 * 1024 * 1024,
        maxMappedIndexBytes: Int = 64 * 1024 * 1024,
        maxCachedChunkCount: Int = 50_000,
        maxChunkBytes: Int = 8 * 1024
    ) {
        self.maxResidentChunkBytes = max(1, maxResidentChunkBytes)
        self.maxMappedIndexBytes = max(1, maxMappedIndexBytes)
        self.maxCachedChunkCount = max(1, maxCachedChunkCount)
        self.maxChunkBytes = max(256, maxChunkBytes)
    }

    public static let `default` = MemoryBudget()
}

public struct ChunkingConfiguration: Codable, Sendable, Hashable {
    public var maxChunkBytes: Int
    public var overlapBytes: Int
    public var preferredBreakCharacters: [Character]

    private enum CodingKeys: String, CodingKey {
        case maxChunkBytes
        case overlapBytes
        case preferredBreakCharacters
    }

    public init(
        maxChunkBytes: Int = 8 * 1024,
        overlapBytes: Int = 64,
        preferredBreakCharacters: [Character] = ["\n", " ", "\t"]
    ) {
        self.maxChunkBytes = max(256, maxChunkBytes)
        self.overlapBytes = max(0, overlapBytes)
        self.preferredBreakCharacters = preferredBreakCharacters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxChunkBytes = max(256, try container.decodeIfPresent(Int.self, forKey: .maxChunkBytes) ?? 8 * 1024)
        overlapBytes = max(0, try container.decodeIfPresent(Int.self, forKey: .overlapBytes) ?? 64)
        preferredBreakCharacters = (try container.decodeIfPresent([String].self, forKey: .preferredBreakCharacters) ?? ["\n", " ", "\t"])
            .compactMap(\ .first)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxChunkBytes, forKey: .maxChunkBytes)
        try container.encode(overlapBytes, forKey: .overlapBytes)
        try container.encode(preferredBreakCharacters.map(String.init), forKey: .preferredBreakCharacters)
    }

    public static let `default` = ChunkingConfiguration()
}

public enum IndexStorageLocation: Codable, Sendable, Hashable {
    case applicationSupport(subdirectory: String)
    case appGroup(identifier: String, subdirectory: String)
    case custom(URL)
    case ephemeral

    public static let `default` = IndexStorageLocation.applicationSupport(subdirectory: "RecallKitRecordIndex")
}

public enum IndexRecoveryStrategy: String, Codable, Sendable, Hashable {
    case fail
    case rebuildFromSource
    case discardCorruptedIndex
}

public enum IndexDataProtection: String, Codable, Sendable, Hashable {
    case complete
    case completeUnlessOpen
    case completeUntilFirstUserAuthentication
    case none
}

/// Configuration for the actor-based record index service, including storage, chunking, and compaction behavior.
public struct RecordIndexServiceConfiguration: Codable, Sendable, Hashable {
    public var indexConfiguration: IndexConfiguration
    public var chunking: ChunkingConfiguration
    public var memoryBudget: MemoryBudget
    public var storageLocation: IndexStorageLocation
    public var dataProtection: IndexDataProtection
    public var recoveryStrategy: IndexRecoveryStrategy
    public var compactionThreshold: Int
    public var compactOnLaunch: Bool

    public init(
        indexConfiguration: IndexConfiguration = .default,
        chunking: ChunkingConfiguration = .default,
        memoryBudget: MemoryBudget = .default,
        storageLocation: IndexStorageLocation = .default,
        dataProtection: IndexDataProtection = .completeUntilFirstUserAuthentication,
        recoveryStrategy: IndexRecoveryStrategy = .rebuildFromSource,
        compactionThreshold: Int = 4_096,
        compactOnLaunch: Bool = false
    ) {
        self.indexConfiguration = indexConfiguration
        self.chunking = chunking
        self.memoryBudget = memoryBudget
        self.storageLocation = storageLocation
        self.dataProtection = dataProtection
        self.recoveryStrategy = recoveryStrategy
        self.compactionThreshold = max(1, compactionThreshold)
        self.compactOnLaunch = compactOnLaunch
    }

    public static let `default` = RecordIndexServiceConfiguration()
}

/// The source record format ingested by RecallKit for indexing and search.
public struct IndexedRecord: Codable, Sendable, Hashable {
    public let id: String
    public let collection: String
    public let title: String?
    public let body: String
    public let fields: [String: String]
    public let tags: [String]
    public let metadata: [String: String]
    public let updatedAtEpochSeconds: UInt64

    public init(
        id: String,
        collection: String,
        title: String? = nil,
        body: String,
        fields: [String: String] = [:],
        tags: [String] = [],
        metadata: [String: String] = [:],
        updatedAtEpochSeconds: UInt64 = IndexMetadata.timestampNow()
    ) {
        self.id = id
        self.collection = collection
        self.title = title
        self.body = body
        self.fields = fields
        self.tags = tags
        self.metadata = metadata
        self.updatedAtEpochSeconds = updatedAtEpochSeconds
    }

    public var searchableFields: [(String, String)] {
        var output: [(String, String)] = []
        if let title, !title.isEmpty {
            output.append(("title", title))
        }
        if !body.isEmpty {
            output.append(("body", body))
        }

        for key in fields.keys.sorted() {
            if let value = fields[key], !value.isEmpty {
                output.append((key, value))
            }
        }

        return output
    }
}

public struct RecordChunk: Codable, Sendable, Hashable {
    public let id: UInt32
    public let recordID: String
    public let collection: String
    public let field: String
    public let ordinal: Int
    public let updatedAtEpochSeconds: UInt64
    public let text: String
    public let tags: [String]
    public let metadata: [String: String]
}

public enum RecordQueryMode: String, Codable, Sendable, Hashable {
    case literal
    case regex
}

/// A query against the actor-based record index.
public struct RecordSearchQuery: Codable, Sendable, Hashable {
    public var text: String
    public var mode: RecordQueryMode
    public var collections: Set<String>
    public var fields: Set<String>
    public var requiredTags: Set<String>
    public var maxResults: Int
    public var caseInsensitive: Bool
    public var smartCase: Bool
    public var useLiteralPrefilter: Bool

    public init(
        text: String,
        mode: RecordQueryMode = .literal,
        collections: Set<String> = [],
        fields: Set<String> = [],
        requiredTags: Set<String> = [],
        maxResults: Int = 20,
        caseInsensitive: Bool = false,
        smartCase: Bool = true,
        useLiteralPrefilter: Bool = true
    ) {
        self.text = text
        self.mode = mode
        self.collections = collections
        self.fields = fields
        self.requiredTags = requiredTags
        self.maxResults = max(1, maxResults)
        self.caseInsensitive = caseInsensitive
        self.smartCase = smartCase
        self.useLiteralPrefilter = useLiteralPrefilter
    }
}

public struct RecordSearchHit: Codable, Sendable, Hashable {
    public let recordID: String
    public let collection: String
    public let field: String
    public let chunkID: UInt32
    public let chunkOrdinal: Int
    public let excerpt: String
    public let score: Double
    public let updatedAtEpochSeconds: UInt64
    public let tags: [String]
    public let metadata: [String: String]

    public init(
        recordID: String,
        collection: String,
        field: String,
        chunkID: UInt32,
        chunkOrdinal: Int,
        excerpt: String,
        score: Double,
        updatedAtEpochSeconds: UInt64,
        tags: [String],
        metadata: [String: String]
    ) {
        self.recordID = recordID
        self.collection = collection
        self.field = field
        self.chunkID = chunkID
        self.chunkOrdinal = chunkOrdinal
        self.excerpt = excerpt
        self.score = score
        self.updatedAtEpochSeconds = updatedAtEpochSeconds
        self.tags = tags
        self.metadata = metadata
    }
}

/// Search results returned from the actor-based record index.
public struct RecordSearchReport: Codable, Sendable, Hashable {
    public let query: RecordSearchQuery
    public let candidateChunkCount: Int
    public let matchedRecordCount: Int
    public let totalMatchCount: Int
    public let hits: [RecordSearchHit]

    public init(
        query: RecordSearchQuery,
        candidateChunkCount: Int,
        matchedRecordCount: Int,
        totalMatchCount: Int,
        hits: [RecordSearchHit]
    ) {
        self.query = query
        self.candidateChunkCount = candidateChunkCount
        self.matchedRecordCount = matchedRecordCount
        self.totalMatchCount = totalMatchCount
        self.hits = hits
    }
}

public enum RecordBenchmarkMode: String, Codable, Sendable, Hashable, CaseIterable {
    case rebuildAndQuery
    case reuseExistingIndex
}

public enum RecordBenchmarkEngine: String, Codable, Sendable, Hashable, CaseIterable {
    case recallKit
    case naiveScan
    case sqliteFTS5
    case coreDataContains
    case coreSpotlight

    public var displayName: String {
        switch self {
        case .recallKit:
            return "RecallKit"
        case .naiveScan:
            return "Naive Scan"
        case .sqliteFTS5:
            return "SQLite FTS5"
        case .coreDataContains:
            return "Core Data Contains"
        case .coreSpotlight:
            return "Core Spotlight"
        }
    }
}

public struct RecordBenchmarkResult: Codable, Sendable, Hashable, Identifiable {
    public let engine: RecordBenchmarkEngine
    public let buildMilliseconds: Double?
    public let queryMilliseconds: Double?
    public let matchedRecordCount: Int?
    public let available: Bool
    public let note: String?

    public init(
        engine: RecordBenchmarkEngine,
        buildMilliseconds: Double?,
        queryMilliseconds: Double?,
        matchedRecordCount: Int?,
        available: Bool,
        note: String? = nil
    ) {
        self.engine = engine
        self.buildMilliseconds = buildMilliseconds
        self.queryMilliseconds = queryMilliseconds
        self.matchedRecordCount = matchedRecordCount
        self.available = available
        self.note = note
    }

    public var id: String {
        engine.rawValue
    }
}

public struct RecordBenchmarkSnapshot: Codable, Sendable, Hashable {
    public let mode: RecordBenchmarkMode
    public let recordCount: Int
    public let candidateChunkCount: Int
    public let results: [RecordBenchmarkResult]

    public init(
        mode: RecordBenchmarkMode,
        recordCount: Int,
        candidateChunkCount: Int,
        results: [RecordBenchmarkResult]
    ) {
        self.mode = mode
        self.recordCount = recordCount
        self.candidateChunkCount = candidateChunkCount
        self.results = results
    }

    public func result(for engine: RecordBenchmarkEngine) -> RecordBenchmarkResult? {
        results.first(where: { $0.engine == engine })
    }

    public var buildMilliseconds: Double {
        result(for: .recallKit)?.buildMilliseconds ?? 0
    }

    public var indexedSearchMilliseconds: Double {
        result(for: .recallKit)?.queryMilliseconds ?? 0
    }

    public var naiveSearchMilliseconds: Double {
        result(for: .naiveScan)?.queryMilliseconds ?? 0
    }

    public var sqliteFTS5SearchMilliseconds: Double? {
        result(for: .sqliteFTS5)?.queryMilliseconds
    }

    public var coreDataSearchMilliseconds: Double? {
        result(for: .coreDataContains)?.queryMilliseconds
    }

    public var coreSpotlightSearchMilliseconds: Double? {
        result(for: .coreSpotlight)?.queryMilliseconds
    }

    public var indexedMatchedRecordCount: Int {
        result(for: .recallKit)?.matchedRecordCount ?? 0
    }

    public var naiveMatchedRecordCount: Int {
        result(for: .naiveScan)?.matchedRecordCount ?? 0
    }

    public var sqliteFTS5MatchedRecordCount: Int? {
        result(for: .sqliteFTS5)?.matchedRecordCount
    }

    public var coreDataMatchedRecordCount: Int? {
        result(for: .coreDataContains)?.matchedRecordCount
    }

    public var coreSpotlightMatchedRecordCount: Int? {
        result(for: .coreSpotlight)?.matchedRecordCount
    }

    public var speedup: Double? {
        guard indexedSearchMilliseconds > 0 else {
            return nil
        }

        return naiveSearchMilliseconds / indexedSearchMilliseconds
    }
}

public enum RecordBenchmarkPhase: String, Codable, Sendable, Hashable {
    case preparing
    case loadingIndex
    case buildingIndex
    case indexedSearch
    case naiveSearch
    case sqliteFTS5Build
    case sqliteFTS5Search
    case coreDataBuild
    case coreDataSearch
    case coreSpotlightBuild
    case coreSpotlightSearch
    case completed
}

public struct RecordBenchmarkProgress: Codable, Sendable, Hashable {
    public let phase: RecordBenchmarkPhase
    public let engine: RecordBenchmarkEngine?
    public let message: String
    public let recordCount: Int
    public let elapsedMilliseconds: Double?
    public let chunkCount: Int?
    public let ngramCount: Int?
    public let candidateChunkCount: Int?
    public let matchedRecordCount: Int?

    public init(
        phase: RecordBenchmarkPhase,
        engine: RecordBenchmarkEngine? = nil,
        message: String,
        recordCount: Int,
        elapsedMilliseconds: Double? = nil,
        chunkCount: Int? = nil,
        ngramCount: Int? = nil,
        candidateChunkCount: Int? = nil,
        matchedRecordCount: Int? = nil
    ) {
        self.phase = phase
        self.engine = engine
        self.message = message
        self.recordCount = recordCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.chunkCount = chunkCount
        self.ngramCount = ngramCount
        self.candidateChunkCount = candidateChunkCount
        self.matchedRecordCount = matchedRecordCount
    }
}

public struct RecordIndexStatus: Codable, Sendable, Hashable {
    public let generationID: String?
    public let storageURL: URL?
    public let recordCount: Int
    public let chunkCount: Int
    public let ngramCount: Int
    public let overlayChunkCount: Int
    public let tombstoneCount: Int
    public let residentChunkBytes: Int
    public let timestamp: UInt64

    public init(
        generationID: String?,
        storageURL: URL?,
        recordCount: Int,
        chunkCount: Int,
        ngramCount: Int,
        overlayChunkCount: Int,
        tombstoneCount: Int,
        residentChunkBytes: Int,
        timestamp: UInt64
    ) {
        self.generationID = generationID
        self.storageURL = storageURL
        self.recordCount = recordCount
        self.chunkCount = chunkCount
        self.ngramCount = ngramCount
        self.overlayChunkCount = overlayChunkCount
        self.tombstoneCount = tombstoneCount
        self.residentChunkBytes = residentChunkBytes
        self.timestamp = timestamp
    }
}

public struct IndexMaintenanceResult: Codable, Sendable, Hashable {
    public let upsertedRecordCount: Int
    public let deletedRecordCount: Int
    public let compacted: Bool
    public let rebuilt: Bool
    public let status: RecordIndexStatus

    public init(
        upsertedRecordCount: Int,
        deletedRecordCount: Int,
        compacted: Bool,
        rebuilt: Bool,
        status: RecordIndexStatus
    ) {
        self.upsertedRecordCount = upsertedRecordCount
        self.deletedRecordCount = deletedRecordCount
        self.compacted = compacted
        self.rebuilt = rebuilt
        self.status = status
    }
}