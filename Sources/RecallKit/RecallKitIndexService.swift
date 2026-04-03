import Foundation

private struct RecordServiceState: Sendable {
    var generationID: String?
    let storageURL: URL?
    var metadata: RecordIndexMetadata
    var baseChunks: [RecordChunk]
    var overlayChunks: [RecordChunk]
    var tombstones: Set<UInt32>
    var activeChunksByID: [UInt32: RecordChunk]
    var activePostingLookup: [UInt64: [UInt32]]
    var recordChunkIDs: [String: Set<UInt32>]
    var nextChunkID: UInt32

    init(persistedState: PersistedRecordIndexState) {
        generationID = persistedState.generationID
        storageURL = persistedState.storageURL
        metadata = persistedState.metadata
        baseChunks = persistedState.baseChunks
        overlayChunks = persistedState.overlayChunks
        tombstones = persistedState.tombstones
        activePostingLookup = persistedState.activePostingLookup

        let activeChunks = (persistedState.baseChunks.filter { !persistedState.tombstones.contains($0.id) } + persistedState.overlayChunks)
            .sorted { $0.id < $1.id }
        activeChunksByID = Dictionary(uniqueKeysWithValues: activeChunks.map { ($0.id, $0) })
        recordChunkIDs = activeChunks.reduce(into: [:]) { partial, chunk in
            partial[recordKey(recordID: chunk.recordID, collection: chunk.collection), default: []].insert(chunk.id)
        }
        nextChunkID = activeChunks.map(\ .id).max().map { $0 &+ 1 } ?? 0
    }

    var activeChunks: [RecordChunk] {
        activeChunksByID.values.sorted { $0.id < $1.id }
    }

    var recordCount: Int {
        Set(activeChunks.map { recordKey(recordID: $0.recordID, collection: $0.collection) }).count
    }

    var residentChunkBytes: Int {
        activeChunksByID.values.reduce(0) { $0 + $1.text.utf8.count }
    }

    mutating func refreshMetadata(using configuration: RecordIndexServiceConfiguration) {
        metadata = RecordIndexMetadata(
            recordCount: recordCount,
            chunkCount: activeChunksByID.count,
            ngramCount: activePostingLookup.count,
            overlayChunkCount: overlayChunks.count,
            tombstoneCount: tombstones.count,
            residentChunkBytes: residentChunkBytes,
            configuration: configuration
        )
    }
}

/// Actor that owns the persisted record index and serves query, update, and maintenance operations.
public actor RecallKitIndexService {
    public let configuration: RecordIndexServiceConfiguration

    private let snapshotProvider: (any RecordSnapshotProvider)?
    private let chunker: RecordChunker
    private var state: RecordServiceState?

    public init(
        configuration: RecordIndexServiceConfiguration = .default,
        snapshotProvider: (any RecordSnapshotProvider)? = nil
    ) {
        self.configuration = configuration
        self.snapshotProvider = snapshotProvider
        self.chunker = RecordChunker(configuration: configuration.chunking)
    }

    /// Loads or rebuilds the persisted index state and returns the current status snapshot.
    @discardableResult
    public func bootstrap() async throws -> RecordIndexStatus {
        let loadedState = try await ensureLoadedState()

        if configuration.compactOnLaunch, !loadedState.overlayChunks.isEmpty || !loadedState.tombstones.isEmpty {
            return try await compact().status
        }

        return makeStatus(from: loadedState)
    }

    @discardableResult
    public func replaceAll(with records: [IndexedRecord]) async throws -> IndexMaintenanceResult {
        try await replaceAllInternal(records: records, rebuilt: true)
    }

    /// Rebuilds the entire index from the configured snapshot provider.
    @discardableResult
    public func rebuild() async throws -> IndexMaintenanceResult {
        guard let snapshotProvider else {
            throw NSError(domain: "RecallKit", code: 50, userInfo: [NSLocalizedDescriptionKey: "No record snapshot provider configured for rebuild"])
        }

        let records = try await snapshotProvider.loadRecords()
        return try await replaceAllInternal(records: records, rebuilt: true)
    }

    /// Inserts or replaces records in the overlay, compacting automatically when the threshold is reached.
    @discardableResult
    public func upsert(_ records: [IndexedRecord]) async throws -> IndexMaintenanceResult {
        var loadedState = try await ensureLoadedState()
        guard !records.isEmpty else {
            return IndexMaintenanceResult(
                upsertedRecordCount: 0,
                deletedRecordCount: 0,
                compacted: false,
                rebuilt: false,
                status: makeStatus(from: loadedState)
            )
        }

        for record in records {
            _ = tombstoneExistingChunks(for: record.id, collection: record.collection, state: &loadedState)

            for preparedChunk in chunker.chunks(for: record) {
                let chunk = RecordChunk(
                    id: loadedState.nextChunkID,
                    recordID: preparedChunk.recordID,
                    collection: preparedChunk.collection,
                    field: preparedChunk.field,
                    ordinal: preparedChunk.ordinal,
                    updatedAtEpochSeconds: preparedChunk.updatedAtEpochSeconds,
                    text: preparedChunk.text,
                    tags: preparedChunk.tags,
                    metadata: preparedChunk.metadata
                )
                loadedState.nextChunkID &+= 1
                insert(chunk: chunk, into: &loadedState)
            }
        }

        try enforceMemoryBudgets(state: loadedState)
        loadedState.refreshMetadata(using: configuration)
        try RecordIndexPersistence.persistOverlay(
            overlayChunks: loadedState.overlayChunks,
            tombstones: loadedState.tombstones,
            activeChunks: loadedState.activeChunks,
            activePostingLookup: loadedState.activePostingLookup,
            generationID: loadedState.generationID,
            configuration: configuration
        )
        state = loadedState

        if loadedState.overlayChunks.count >= configuration.compactionThreshold {
            let compacted = try await compactInternal(upsertedRecordCount: records.count, deletedRecordCount: 0, rebuilt: false)
            return compacted
        }

        return IndexMaintenanceResult(
            upsertedRecordCount: records.count,
            deletedRecordCount: 0,
            compacted: false,
            rebuilt: false,
            status: makeStatus(from: loadedState)
        )
    }

    /// Deletes records by ID, optionally constrained to a single collection.
    @discardableResult
    public func delete(recordIDs: [String], in collection: String? = nil) async throws -> IndexMaintenanceResult {
        var loadedState = try await ensureLoadedState()
        guard !recordIDs.isEmpty else {
            return IndexMaintenanceResult(
                upsertedRecordCount: 0,
                deletedRecordCount: 0,
                compacted: false,
                rebuilt: false,
                status: makeStatus(from: loadedState)
            )
        }

        var deletedCount = 0
        if let collection {
            for recordID in recordIDs {
                deletedCount += tombstoneExistingChunks(for: recordID, collection: collection, state: &loadedState) ? 1 : 0
            }
        } else {
            let matchingKeys = loadedState.recordChunkIDs.keys.filter { key in
                let parts = key.split(separator: "\u{001F}", maxSplits: 1).map(String.init)
                return parts.count == 2 && recordIDs.contains(parts[1])
            }

            for key in matchingKeys {
                let parts = key.split(separator: "\u{001F}", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    deletedCount += tombstoneExistingChunks(for: parts[1], collection: parts[0], state: &loadedState) ? 1 : 0
                }
            }
        }

        try enforceMemoryBudgets(state: loadedState)
        loadedState.refreshMetadata(using: configuration)
        try RecordIndexPersistence.persistOverlay(
            overlayChunks: loadedState.overlayChunks,
            tombstones: loadedState.tombstones,
            activeChunks: loadedState.activeChunks,
            activePostingLookup: loadedState.activePostingLookup,
            generationID: loadedState.generationID,
            configuration: configuration
        )
        state = loadedState

        return IndexMaintenanceResult(
            upsertedRecordCount: 0,
            deletedRecordCount: deletedCount,
            compacted: false,
            rebuilt: false,
            status: makeStatus(from: loadedState)
        )
    }

    /// Merges the overlay and tombstones back into a compact persisted snapshot.
    @discardableResult
    public func compact() async throws -> IndexMaintenanceResult {
        try await compactInternal(upsertedRecordCount: 0, deletedRecordCount: 0, rebuilt: false)
    }

    /// Executes a literal or regex query against the active record index.
    public func search(_ query: RecordSearchQuery) async throws -> RecordSearchReport {
        let loadedState = try await ensureLoadedState()
        let compiledQuery = try compile(query)
        let allChunkIDs = Set(loadedState.activeChunksByID.keys)
        let candidateIDs = compiledQuery.prefilterEnabled
            ? execute(compiledQuery.plan, postings: loadedState.activePostingLookup, allChunkIDs: allChunkIDs).sorted()
            : allChunkIDs.sorted()

        let filteredChunks = candidateIDs.compactMap { loadedState.activeChunksByID[$0] }.filter {
            (query.collections.isEmpty || query.collections.contains($0.collection))
                && (query.fields.isEmpty || query.fields.contains($0.field))
                && query.requiredTags.isSubset(of: Set($0.tags))
        }

        let verifiedHits = try Parallel.compactMapOrdered(filteredChunks) { chunk -> (RecordSearchHit, Int)? in
            let matchCount = try Self.matchCount(in: chunk.text, compiledQuery: compiledQuery)
            guard matchCount > 0 else {
                return nil
            }

            let score = Double(matchCount * 1_000) + (Double(chunk.updatedAtEpochSeconds) / 1_000_000.0)
            return (
                RecordSearchHit(
                    recordID: chunk.recordID,
                    collection: chunk.collection,
                    field: chunk.field,
                    chunkID: chunk.id,
                    chunkOrdinal: chunk.ordinal,
                    excerpt: Self.makeExcerpt(in: chunk.text, compiledQuery: compiledQuery),
                    score: score,
                    updatedAtEpochSeconds: chunk.updatedAtEpochSeconds,
                    tags: chunk.tags,
                    metadata: chunk.metadata
                ),
                matchCount
            )
        }
        .sorted { lhs, rhs in
            if lhs.0.score != rhs.0.score {
                return lhs.0.score > rhs.0.score
            }
            return lhs.0.chunkID < rhs.0.chunkID
        }

        let limitedHits = Array(verifiedHits.prefix(query.maxResults))
        let matchedRecordCount = Set(verifiedHits.map { $0.0.recordID }).count
        let totalMatchCount = verifiedHits.reduce(0) { $0 + $1.1 }

        return RecordSearchReport(
            query: query,
            candidateChunkCount: filteredChunks.count,
            matchedRecordCount: matchedRecordCount,
            totalMatchCount: totalMatchCount,
            hits: limitedHits.map(\ .0)
        )
    }

    public func status() async throws -> RecordIndexStatus {
        makeStatus(from: try await ensureLoadedState())
    }

    private func ensureLoadedState() async throws -> RecordServiceState {
        if let state {
            return state
        }

        do {
            let persistedState = try RecordIndexPersistence.load(configuration: configuration)
            let serviceState = RecordServiceState(persistedState: persistedState)
            try enforceMemoryBudgets(state: serviceState)
            state = serviceState
            return serviceState
        } catch {
            return try await recover(from: error)
        }
    }

    private func recover(from error: Error) async throws -> RecordServiceState {
        switch configuration.recoveryStrategy {
        case .fail:
            throw error

        case .discardCorruptedIndex:
            try? RecordIndexPersistence.removeStore(configuration: configuration)
            let emptyState = RecordServiceState(persistedState: try RecordIndexPersistence.load(configuration: configuration))
            state = emptyState
            return emptyState

        case .rebuildFromSource:
            if let snapshotProvider {
                try? RecordIndexPersistence.removeStore(configuration: configuration)
                let records = try await snapshotProvider.loadRecords()
                let result = try await replaceAllInternal(records: records, rebuilt: true)
                guard let state else {
                    throw error
                }
                _ = result
                return state
            }

            let emptyState = RecordServiceState(persistedState: try RecordIndexPersistence.load(configuration: configuration))
            state = emptyState
            return emptyState
        }
    }

    private func replaceAllInternal(records: [IndexedRecord], rebuilt: Bool) async throws -> IndexMaintenanceResult {
        let normalizedChunks = buildNormalizedChunks(from: records)
        let persistedState = try RecordIndexPersistence.replaceAll(chunks: normalizedChunks, configuration: configuration)
        let loadedState = RecordServiceState(persistedState: persistedState)
        try enforceMemoryBudgets(state: loadedState)
        state = loadedState

        return IndexMaintenanceResult(
            upsertedRecordCount: records.count,
            deletedRecordCount: 0,
            compacted: rebuilt,
            rebuilt: rebuilt,
            status: makeStatus(from: loadedState)
        )
    }

    private func compactInternal(
        upsertedRecordCount: Int,
        deletedRecordCount: Int,
        rebuilt: Bool
    ) async throws -> IndexMaintenanceResult {
        let loadedState = try await ensureLoadedState()
        let compactedChunks = buildNormalizedChunks(from: loadedState.activeChunks)
        let persistedState = try RecordIndexPersistence.replaceAll(chunks: compactedChunks, configuration: configuration)
        let compactedState = RecordServiceState(persistedState: persistedState)
        try enforceMemoryBudgets(state: compactedState)
        state = compactedState

        return IndexMaintenanceResult(
            upsertedRecordCount: upsertedRecordCount,
            deletedRecordCount: deletedRecordCount,
            compacted: true,
            rebuilt: rebuilt,
            status: makeStatus(from: compactedState)
        )
    }

    private func buildNormalizedChunks(from records: [IndexedRecord]) -> [RecordChunk] {
        let preparedChunks: [PreparedRecordChunk]

        if records.count >= 128,
           let parallelPrepared = try? Parallel.mapOrdered(records, transform: { record in
               self.chunker.chunks(for: record)
           }) {
            preparedChunks = parallelPrepared.flatMap { $0 }
        } else {
            preparedChunks = records.flatMap(chunker.chunks(for:))
        }

        return buildNormalizedChunks(from: preparedChunks)
    }

    private func buildNormalizedChunks(from preparedChunks: [PreparedRecordChunk]) -> [RecordChunk] {
        preparedChunks.enumerated().map { offset, chunk in
            RecordChunk(
                id: UInt32(offset),
                recordID: chunk.recordID,
                collection: chunk.collection,
                field: chunk.field,
                ordinal: chunk.ordinal,
                updatedAtEpochSeconds: chunk.updatedAtEpochSeconds,
                text: chunk.text,
                tags: chunk.tags,
                metadata: chunk.metadata
            )
        }
    }

    private func buildNormalizedChunks(from chunks: [RecordChunk]) -> [RecordChunk] {
        chunks.sorted { lhs, rhs in
            if lhs.collection != rhs.collection { return lhs.collection < rhs.collection }
            if lhs.recordID != rhs.recordID { return lhs.recordID < rhs.recordID }
            if lhs.field != rhs.field { return lhs.field < rhs.field }
            return lhs.ordinal < rhs.ordinal
        }.enumerated().map { offset, chunk in
            RecordChunk(
                id: UInt32(offset),
                recordID: chunk.recordID,
                collection: chunk.collection,
                field: chunk.field,
                ordinal: chunk.ordinal,
                updatedAtEpochSeconds: chunk.updatedAtEpochSeconds,
                text: chunk.text,
                tags: chunk.tags,
                metadata: chunk.metadata
            )
        }
    }

    private func tombstoneExistingChunks(
        for recordID: String,
        collection: String,
        state: inout RecordServiceState
    ) -> Bool {
        let key = recordKey(recordID: recordID, collection: collection)
        guard let chunkIDs = state.recordChunkIDs[key], !chunkIDs.isEmpty else {
            return false
        }

        state.tombstones.formUnion(chunkIDs)
        state.recordChunkIDs.removeValue(forKey: key)

        for chunkID in chunkIDs {
            guard let chunk = state.activeChunksByID.removeValue(forKey: chunkID) else {
                continue
            }
            remove(chunkID: chunkID, text: chunk.text, from: &state.activePostingLookup)
        }

        return true
    }

    private func insert(chunk: RecordChunk, into state: inout RecordServiceState) {
        state.overlayChunks.append(chunk)
        state.activeChunksByID[chunk.id] = chunk
        state.recordChunkIDs[recordKey(recordID: chunk.recordID, collection: chunk.collection), default: []].insert(chunk.id)

        let extractor = SparseNGramExtractor(maxNGramLength: configuration.indexConfiguration.maxNGramLength)
        let hashes = extractor.extractHashes(from: chunk.text)
        for hash in hashes {
            state.activePostingLookup[hash] = sortedUnion(state.activePostingLookup[hash] ?? [], [chunk.id])
        }
    }

    private func remove(chunkID: UInt32, text: String, from postings: inout [UInt64: [UInt32]]) {
        let extractor = SparseNGramExtractor(maxNGramLength: configuration.indexConfiguration.maxNGramLength)
        let hashes = extractor.extractHashes(from: text)
        for hash in hashes {
            guard let current = postings[hash] else {
                continue
            }
            let filtered = current.filter { $0 != chunkID }
            if filtered.isEmpty {
                postings.removeValue(forKey: hash)
            } else {
                postings[hash] = filtered
            }
        }
    }

    private func compile(_ query: RecordSearchQuery) throws -> CompiledRecordQuery {
        let caseInsensitive = query.caseInsensitive || (query.smartCase && !query.text.contains(where: \ .isUppercase))
        let plannerPattern = query.mode == .literal ? NSRegularExpression.escapedPattern(for: query.text) : query.text
        let regex = try NSRegularExpression(
            pattern: plannerPattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )

        return CompiledRecordQuery(
            regex: regex,
            literal: query.mode == .literal ? query.text : nil,
            caseInsensitive: caseInsensitive,
            plan: RegexQueryPlanner().plan(
                for: caseInsensitive ? ".*" : plannerPattern,
                configuration: configuration.indexConfiguration
            ),
            prefilterEnabled: query.useLiteralPrefilter && !caseInsensitive
        )
    }

    private static func matchCount(in text: String, compiledQuery: CompiledRecordQuery) throws -> Int {
        if let literal = compiledQuery.literal {
            return literalMatches(in: text, literal: literal, caseInsensitive: compiledQuery.caseInsensitive).count
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return compiledQuery.regex.matches(in: text, range: range).count
    }

    private static func literalMatches(in text: String, literal: String, caseInsensitive: Bool) -> [Range<String.Index>] {
        guard !literal.isEmpty else {
            return []
        }

        var matches: [Range<String.Index>] = []
        var searchStart = text.startIndex
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []

        while searchStart <= text.endIndex,
              let range = text.range(of: literal, options: options, range: searchStart..<text.endIndex) {
            matches.append(range)
            searchStart = range.isEmpty ? text.index(after: searchStart) : range.upperBound
        }

        return matches
    }

    private static func makeExcerpt(in text: String, compiledQuery: CompiledRecordQuery) -> String {
        let matchRange: Range<String.Index>?

        if let literal = compiledQuery.literal {
            matchRange = literalMatches(in: text, literal: literal, caseInsensitive: compiledQuery.caseInsensitive).first
        } else {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            matchRange = compiledQuery.regex.firstMatch(in: text, range: nsRange).flatMap { Range($0.range, in: text) }
        }

        guard let matchRange else {
            return String(text.prefix(200))
        }

        let start = text.index(matchRange.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(matchRange.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func execute(
        _ plan: QueryPlan,
        postings: [UInt64: [UInt32]],
        allChunkIDs: Set<UInt32>
    ) -> Set<UInt32> {
        switch plan {
        case .scanAll:
            return allChunkIDs

        case let .lookup(hash):
            return Set(postings[hash] ?? [])

        case let .and(children):
            let narrowedChildren = children.filter { $0 != .scanAll }
            guard let first = narrowedChildren.first else {
                return allChunkIDs
            }

            var result = execute(first, postings: postings, allChunkIDs: allChunkIDs)
            for child in narrowedChildren.dropFirst() {
                result.formIntersection(execute(child, postings: postings, allChunkIDs: allChunkIDs))
                if result.isEmpty {
                    break
                }
            }
            return result

        case let .or(children):
            if children.contains(.scanAll) {
                return allChunkIDs
            }

            return children.reduce(into: Set<UInt32>()) { partial, child in
                partial.formUnion(execute(child, postings: postings, allChunkIDs: allChunkIDs))
            }
        }
    }

    private func makeStatus(from state: RecordServiceState) -> RecordIndexStatus {
        RecordIndexStatus(
            generationID: state.generationID,
            storageURL: state.storageURL,
            recordCount: state.recordCount,
            chunkCount: state.activeChunksByID.count,
            ngramCount: state.activePostingLookup.count,
            overlayChunkCount: state.overlayChunks.count,
            tombstoneCount: state.tombstones.count,
            residentChunkBytes: state.residentChunkBytes,
            timestamp: state.metadata.timestamp
        )
    }

    private func enforceMemoryBudgets(state: RecordServiceState) throws {
        if state.residentChunkBytes > configuration.memoryBudget.maxResidentChunkBytes {
            throw RecordIndexPersistenceError.residentBudgetExceeded(state.residentChunkBytes)
        }

        if state.activeChunksByID.count > configuration.memoryBudget.maxCachedChunkCount {
            throw RecordIndexPersistenceError.chunkCountBudgetExceeded(state.activeChunksByID.count)
        }

        if let oversized = state.activeChunksByID.values.first(where: { $0.text.utf8.count > configuration.memoryBudget.maxChunkBytes }) {
            throw RecordIndexPersistenceError.chunkTooLarge(oversized.recordID)
        }
    }

    private func sortedUnion(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        var leftIndex = 0
        var rightIndex = 0
        var merged: [UInt32] = []

        while leftIndex < lhs.count && rightIndex < rhs.count {
            let left = lhs[leftIndex]
            let right = rhs[rightIndex]
            if left == right {
                merged.append(left)
                leftIndex += 1
                rightIndex += 1
            } else if left < right {
                merged.append(left)
                leftIndex += 1
            } else {
                merged.append(right)
                rightIndex += 1
            }
        }

        if leftIndex < lhs.count { merged.append(contentsOf: lhs[leftIndex...]) }
        if rightIndex < rhs.count { merged.append(contentsOf: rhs[rightIndex...]) }
        return merged
    }
}

private struct CompiledRecordQuery: Sendable {
    let regex: NSRegularExpression
    let literal: String?
    let caseInsensitive: Bool
    let plan: QueryPlan
    let prefilterEnabled: Bool
}

private func recordKey(recordID: String, collection: String) -> String {
    "\(collection)\u{001F}\(recordID)"
}