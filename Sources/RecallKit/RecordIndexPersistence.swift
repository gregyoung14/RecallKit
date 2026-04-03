import Foundation

struct RecordIndexMetadata: Codable, Sendable, Hashable {
    static let currentVersion = 1

    let version: Int
    let recordCount: Int
    let chunkCount: Int
    let ngramCount: Int
    let overlayChunkCount: Int
    let tombstoneCount: Int
    let residentChunkBytes: Int
    let timestamp: UInt64
    let configuration: RecordIndexServiceConfiguration

    init(
        version: Int = currentVersion,
        recordCount: Int,
        chunkCount: Int,
        ngramCount: Int,
        overlayChunkCount: Int,
        tombstoneCount: Int,
        residentChunkBytes: Int,
        timestamp: UInt64 = IndexMetadata.timestampNow(),
        configuration: RecordIndexServiceConfiguration
    ) {
        self.version = version
        self.recordCount = recordCount
        self.chunkCount = chunkCount
        self.ngramCount = ngramCount
        self.overlayChunkCount = overlayChunkCount
        self.tombstoneCount = tombstoneCount
        self.residentChunkBytes = residentChunkBytes
        self.timestamp = timestamp
        self.configuration = configuration
    }
}

struct PersistedRecordIndexState: Sendable {
    let generationID: String?
    let storageURL: URL?
    let metadata: RecordIndexMetadata
    let baseChunks: [RecordChunk]
    let overlayChunks: [RecordChunk]
    let tombstones: Set<UInt32>
    let activePostingLookup: [UInt64: [UInt32]]
}

enum RecordIndexPersistence {
    private static let generationsDirectoryName = "generations"
    private static let currentFileName = "CURRENT"
    private static let overlayDirectoryName = "overlay"
    private static let chunksFileName = "chunks.json"

    static func load(configuration: RecordIndexServiceConfiguration) throws -> PersistedRecordIndexState {
        guard let storageURL = try directoryURL(for: configuration.storageLocation) else {
            return emptyState(storageURL: nil, configuration: configuration)
        }

        let currentURL = storageURL.appendingPathComponent(currentFileName)
        guard FileManager.default.fileExists(atPath: currentURL.path) else {
            return emptyState(storageURL: storageURL, configuration: configuration)
        }

        let generationID = try String(contentsOf: currentURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let generationURL = storageURL
            .appendingPathComponent(generationsDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)

        let metadata = try readMetadata(from: generationURL.appendingPathComponent("meta.json"))
        guard metadata.version == RecordIndexMetadata.currentVersion else {
            throw RecordIndexPersistenceError.versionMismatch(metadata.version)
        }

        let baseChunks = try readChunks(from: generationURL.appendingPathComponent(chunksFileName))
        let basePostingLookup = try loadPostingLookup(
            from: generationURL,
            maxMappedIndexBytes: configuration.memoryBudget.maxMappedIndexBytes
        )

        let overlayURL = generationURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)
        let overlayChunks: [RecordChunk]
        let overlayPostingLookup: [UInt64: [UInt32]]
        let tombstones: Set<UInt32>

        if FileManager.default.fileExists(atPath: overlayURL.path) {
            overlayChunks = try readChunks(from: overlayURL.appendingPathComponent(chunksFileName))
            overlayPostingLookup = try loadPostingLookup(
                from: overlayURL,
                maxMappedIndexBytes: configuration.memoryBudget.maxMappedIndexBytes
            )
            tombstones = Set(try TombstoneCodec.read(from: overlayURL.appendingPathComponent("tombstones.bin")))
        } else {
            overlayChunks = []
            overlayPostingLookup = [:]
            tombstones = []
        }

        let activeChunks = makeActiveChunks(baseChunks: baseChunks, overlayChunks: overlayChunks, tombstones: tombstones)
        try enforceBudgets(chunks: activeChunks, configuration: configuration)

        return PersistedRecordIndexState(
            generationID: generationID,
            storageURL: storageURL,
            metadata: metadata,
            baseChunks: baseChunks,
            overlayChunks: overlayChunks,
            tombstones: tombstones,
            activePostingLookup: mergePostingLookups(base: basePostingLookup, overlay: overlayPostingLookup, tombstones: tombstones)
        )
    }

    static func replaceAll(chunks: [RecordChunk], configuration: RecordIndexServiceConfiguration) throws -> PersistedRecordIndexState {
        let activePostingLookup = buildPostingLookup(for: chunks, indexConfiguration: configuration.indexConfiguration)
        let metadata = makeMetadata(
            activeChunks: chunks,
            activePostingLookup: activePostingLookup,
            overlayChunkCount: 0,
            tombstoneCount: 0,
            configuration: configuration
        )

        guard let storageURL = try directoryURL(for: configuration.storageLocation) else {
            return PersistedRecordIndexState(
                generationID: nil,
                storageURL: nil,
                metadata: metadata,
                baseChunks: chunks,
                overlayChunks: [],
                tombstones: [],
                activePostingLookup: activePostingLookup
            )
        }

        try FileLock.withExclusiveLock(at: storageURL.appendingPathComponent("lock")) {
            try FileManager.default.createDirectory(
                at: storageURL.appendingPathComponent(generationsDirectoryName, isDirectory: true),
                withIntermediateDirectories: true
            )

            let generationID = "\(IndexMetadata.timestampNow())"
            let tempGenerationURL = storageURL
                .appendingPathComponent(generationsDirectoryName, isDirectory: true)
                .appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
            let generationURL = storageURL
                .appendingPathComponent(generationsDirectoryName, isDirectory: true)
                .appendingPathComponent(generationID, isDirectory: true)

            try FileManager.default.createDirectory(at: tempGenerationURL, withIntermediateDirectories: true)
            try writeChunks(chunks, to: tempGenerationURL.appendingPathComponent(chunksFileName))
            try writePostingLookup(activePostingLookup, to: tempGenerationURL)
            try writeMetadata(metadata, to: tempGenerationURL.appendingPathComponent("meta.json"))
            try applyDataProtection(to: tempGenerationURL, protection: configuration.dataProtection)

            if FileManager.default.fileExists(atPath: generationURL.path) {
                try FileManager.default.removeItem(at: generationURL)
            }

            try FileManager.default.moveItem(at: tempGenerationURL, to: generationURL)
            try writeCurrent(generationID: generationID, to: storageURL)
        }

        return try load(configuration: configuration)
    }

    static func persistOverlay(
        overlayChunks: [RecordChunk],
        tombstones: Set<UInt32>,
        activeChunks: [RecordChunk],
        activePostingLookup: [UInt64: [UInt32]],
        generationID: String?,
        configuration: RecordIndexServiceConfiguration
    ) throws {
        guard let generationID, let storageURL = try directoryURL(for: configuration.storageLocation) else {
            return
        }

        let generationURL = storageURL
            .appendingPathComponent(generationsDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
        let overlayURL = generationURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)
        let tempOverlayURL = generationURL.appendingPathComponent("\(overlayDirectoryName).tmp-\(UUID().uuidString)", isDirectory: true)
        let metadata = makeMetadata(
            activeChunks: activeChunks,
            activePostingLookup: activePostingLookup,
            overlayChunkCount: overlayChunks.count,
            tombstoneCount: tombstones.count,
            configuration: configuration
        )

        try FileLock.withExclusiveLock(at: storageURL.appendingPathComponent("lock")) {
            if FileManager.default.fileExists(atPath: tempOverlayURL.path) {
                try FileManager.default.removeItem(at: tempOverlayURL)
            }
            try FileManager.default.createDirectory(at: tempOverlayURL, withIntermediateDirectories: true)
            try writeChunks(overlayChunks, to: tempOverlayURL.appendingPathComponent(chunksFileName))
            try writePostingLookup(buildPostingLookup(for: overlayChunks, indexConfiguration: configuration.indexConfiguration), to: tempOverlayURL)
            try TombstoneCodec.write(Array(tombstones).sorted(), to: tempOverlayURL.appendingPathComponent("tombstones.bin"))
            try applyDataProtection(to: tempOverlayURL, protection: configuration.dataProtection)

            if FileManager.default.fileExists(atPath: overlayURL.path) {
                try FileManager.default.removeItem(at: overlayURL)
            }
            try FileManager.default.moveItem(at: tempOverlayURL, to: overlayURL)
            try writeMetadata(metadata, to: generationURL.appendingPathComponent("meta.json"))
        }
    }

    static func removeStore(configuration: RecordIndexServiceConfiguration) throws {
        guard let storageURL = try resolvedDirectoryURL(for: configuration.storageLocation),
              FileManager.default.fileExists(atPath: storageURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: storageURL)
    }

    static func resolvedDirectoryURL(for location: IndexStorageLocation) throws -> URL? {
        try directoryURL(for: location)
    }

    private static func emptyState(storageURL: URL?, configuration: RecordIndexServiceConfiguration) -> PersistedRecordIndexState {
        PersistedRecordIndexState(
            generationID: nil,
            storageURL: storageURL,
            metadata: makeMetadata(
                activeChunks: [],
                activePostingLookup: [:],
                overlayChunkCount: 0,
                tombstoneCount: 0,
                configuration: configuration
            ),
            baseChunks: [],
            overlayChunks: [],
            tombstones: [],
            activePostingLookup: [:]
        )
    }

    private static func directoryURL(for location: IndexStorageLocation) throws -> URL? {
        let fileManager = FileManager.default

        switch location {
        case let .applicationSupport(subdirectory):
            let baseURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directoryURL = baseURL.appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return directoryURL

        case let .appGroup(identifier, subdirectory):
            guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                throw RecordIndexPersistenceError.invalidAppGroup(identifier)
            }
            let directoryURL = groupURL.appendingPathComponent(subdirectory, isDirectory: true)
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return directoryURL

        case let .custom(url):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url

        case .ephemeral:
            return nil
        }
    }

    private static func makeMetadata(
        activeChunks: [RecordChunk],
        activePostingLookup: [UInt64: [UInt32]],
        overlayChunkCount: Int,
        tombstoneCount: Int,
        configuration: RecordIndexServiceConfiguration
    ) -> RecordIndexMetadata {
        let recordCount = Set(activeChunks.map { recordKey(recordID: $0.recordID, collection: $0.collection) }).count
        return RecordIndexMetadata(
            recordCount: recordCount,
            chunkCount: activeChunks.count,
            ngramCount: activePostingLookup.count,
            overlayChunkCount: overlayChunkCount,
            tombstoneCount: tombstoneCount,
            residentChunkBytes: activeChunks.reduce(0) { $0 + $1.text.utf8.count },
            configuration: configuration
        )
    }

    private static func buildPostingLookup(
        for chunks: [RecordChunk],
        indexConfiguration: IndexConfiguration
    ) -> [UInt64: [UInt32]] {
        guard !chunks.isEmpty else {
            return [:]
        }

        let extractor = SparseNGramExtractor(maxNGramLength: indexConfiguration.maxNGramLength)

        if chunks.count < 256 || ProcessInfo.processInfo.activeProcessorCount <= 1 {
            return buildPostingLookupBatch(for: chunks[...], extractor: extractor)
        }

        let batchCount = min(max(1, ProcessInfo.processInfo.activeProcessorCount * 2), chunks.count)
        let ranges = batchRanges(count: chunks.count, batchCount: batchCount)

        do {
            let partialLookups = try Parallel.mapOrdered(ranges) { range in
                buildPostingLookupBatch(for: chunks[range], extractor: extractor)
            }

            var merged: [UInt64: [UInt32]] = [:]
            for partialLookup in partialLookups {
                for (hash, postings) in partialLookup {
                    if let existing = merged[hash] {
                        merged[hash] = sortedUnion(existing, postings)
                    } else {
                        merged[hash] = postings
                    }
                }
            }

            return merged
        } catch {
            return buildPostingLookupBatch(for: chunks[...], extractor: extractor)
        }
    }

    private static func buildPostingLookupBatch(
        for chunks: ArraySlice<RecordChunk>,
        extractor: SparseNGramExtractor
    ) -> [UInt64: [UInt32]] {
        var postingLookup: [UInt64: [UInt32]] = [:]

        for chunk in chunks {
            let hashes = extractor.extractHashes(from: chunk.text)
            for hash in hashes {
                postingLookup[hash, default: []].append(chunk.id)
            }
        }

        return postingLookup
    }

    private static func batchRanges(count: Int, batchCount: Int) -> [Range<Int>] {
        guard count > 0 else {
            return []
        }

        let normalizedBatchCount = max(1, min(batchCount, count))
        let batchSize = max(1, (count + normalizedBatchCount - 1) / normalizedBatchCount)

        return stride(from: 0, to: count, by: batchSize).map { start in
            start..<min(count, start + batchSize)
        }
    }

    private static func mergePostingLookups(
        base: [UInt64: [UInt32]],
        overlay: [UInt64: [UInt32]],
        tombstones: Set<UInt32>
    ) -> [UInt64: [UInt32]] {
        var merged: [UInt64: [UInt32]] = [:]

        for (hash, postings) in base {
            let filtered = postings.filter { !tombstones.contains($0) }
            if !filtered.isEmpty {
                merged[hash] = filtered
            }
        }

        for (hash, postings) in overlay {
            merged[hash] = sortedUnion(merged[hash] ?? [], postings)
        }

        return merged
    }

    private static func makeActiveChunks(
        baseChunks: [RecordChunk],
        overlayChunks: [RecordChunk],
        tombstones: Set<UInt32>
    ) -> [RecordChunk] {
        let activeBase = baseChunks.filter { !tombstones.contains($0.id) }
        return (activeBase + overlayChunks).sorted { $0.id < $1.id }
    }

    private static func loadPostingLookup(from directoryURL: URL, maxMappedIndexBytes: Int) throws -> [UInt64: [UInt32]] {
        let lookupData = try readData(at: directoryURL.appendingPathComponent("lookup.bin"), maxMappedIndexBytes: maxMappedIndexBytes)
        let postingsData = try readData(at: directoryURL.appendingPathComponent("postings.bin"), maxMappedIndexBytes: maxMappedIndexBytes)
        let lookupTable = try BinaryLookupTable(data: lookupData)

        return lookupTable.entries().reduce(into: [UInt64: [UInt32]]()) { partial, entry in
            partial[entry.hash] = PostingCodec.decode(postingsData, offset: Int(entry.offset), length: Int(entry.length))
        }
    }

    private static func readData(at fileURL: URL, maxMappedIndexBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0

        if fileSize <= maxMappedIndexBytes {
            return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        }

        return try Data(contentsOf: fileURL)
    }

    private static func writePostingLookup(_ postingLookup: [UInt64: [UInt32]], to directoryURL: URL) throws {
        var postingsData = Data()
        var lookupEntries: [LookupTableEntry] = []

        for hash in postingLookup.keys.sorted() {
            let encoded = PostingCodec.encode(postingLookup[hash] ?? [])
            let offset = UInt64(postingsData.count)
            postingsData.append(encoded)
            lookupEntries.append(LookupTableEntry(hash: hash, offset: offset, length: UInt32(encoded.count)))
        }

        try postingsData.write(to: directoryURL.appendingPathComponent("postings.bin"), options: .atomic)
        try BinaryLookupTable.write(entries: lookupEntries, to: directoryURL.appendingPathComponent("lookup.bin"))
    }

    private static func writeChunks(_ chunks: [RecordChunk], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(chunks)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func readChunks(from fileURL: URL) throws -> [RecordChunk] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([RecordChunk].self, from: data)
    }

    private static func writeMetadata(_ metadata: RecordIndexMetadata, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func readMetadata(from fileURL: URL) throws -> RecordIndexMetadata {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(RecordIndexMetadata.self, from: data)
    }

    private static func writeCurrent(generationID: String, to storageURL: URL) throws {
        let currentURL = storageURL.appendingPathComponent(currentFileName)
        let temporaryURL = storageURL.appendingPathComponent("\(currentFileName).tmp")
        try generationID.write(to: temporaryURL, atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: currentURL.path) {
            try FileManager.default.removeItem(at: currentURL)
        }

        try FileManager.default.moveItem(at: temporaryURL, to: currentURL)
        try applyDataProtection(to: currentURL, protection: .completeUnlessOpen)
    }

    private static func enforceBudgets(chunks: [RecordChunk], configuration: RecordIndexServiceConfiguration) throws {
        let residentChunkBytes = chunks.reduce(0) { $0 + $1.text.utf8.count }
        guard residentChunkBytes <= configuration.memoryBudget.maxResidentChunkBytes else {
            throw RecordIndexPersistenceError.residentBudgetExceeded(residentChunkBytes)
        }

        guard chunks.count <= configuration.memoryBudget.maxCachedChunkCount else {
            throw RecordIndexPersistenceError.chunkCountBudgetExceeded(chunks.count)
        }

        if let oversizedChunk = chunks.first(where: { $0.text.utf8.count > configuration.memoryBudget.maxChunkBytes }) {
            throw RecordIndexPersistenceError.chunkTooLarge(oversizedChunk.recordID)
        }
    }

    private static func sortedUnion(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        var leftIndex = 0
        var rightIndex = 0
        var merged: [UInt32] = []

        while leftIndex < lhs.count && rightIndex < rhs.count {
            let leftValue = lhs[leftIndex]
            let rightValue = rhs[rightIndex]

            if leftValue == rightValue {
                merged.append(leftValue)
                leftIndex += 1
                rightIndex += 1
            } else if leftValue < rightValue {
                merged.append(leftValue)
                leftIndex += 1
            } else {
                merged.append(rightValue)
                rightIndex += 1
            }
        }

        if leftIndex < lhs.count {
            merged.append(contentsOf: lhs[leftIndex...])
        }
        if rightIndex < rhs.count {
            merged.append(contentsOf: rhs[rightIndex...])
        }

        return merged
    }

    private static func recordKey(recordID: String, collection: String) -> String {
        "\(collection)\u{001F}\(recordID)"
    }

    private static func applyDataProtection(to fileURL: URL, protection: IndexDataProtection) throws {
        #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
        let attributes: [FileAttributeKey: Any] = [
            .protectionKey: fileProtectionType(for: protection)
        ]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           let enumerator = FileManager.default.enumerator(at: fileURL, includingPropertiesForKeys: nil) {
            for case let nestedURL as URL in enumerator {
                try FileManager.default.setAttributes(attributes, ofItemAtPath: nestedURL.path)
            }
        }
        #endif
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || targetEnvironment(macCatalyst)
    private static func fileProtectionType(for protection: IndexDataProtection) -> FileProtectionType {
        switch protection {
        case .complete:
            return .complete
        case .completeUnlessOpen:
            return .completeUnlessOpen
        case .completeUntilFirstUserAuthentication:
            return .completeUntilFirstUserAuthentication
        case .none:
            return .none
        }
    }
    #endif
}

enum RecordIndexPersistenceError: LocalizedError {
    case invalidAppGroup(String)
    case versionMismatch(Int)
    case residentBudgetExceeded(Int)
    case chunkCountBudgetExceeded(Int)
    case chunkTooLarge(String)

    var errorDescription: String? {
        switch self {
        case let .invalidAppGroup(identifier):
            return "Unable to resolve app group container for \(identifier)"
        case let .versionMismatch(version):
            return "Unsupported record index version \(version)"
        case let .residentBudgetExceeded(bytes):
            return "Record index exceeds resident memory budget with \(bytes) bytes"
        case let .chunkCountBudgetExceeded(count):
            return "Record index exceeds cached chunk budget with \(count) chunks"
        case let .chunkTooLarge(recordID):
            return "Record \(recordID) contains a chunk larger than the configured budget"
        }
    }
}