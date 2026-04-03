import Foundation

enum IndexPersistence {
    private static let indexDirectoryName = ".frg"
    private static let generationsDirectoryName = "generations"
    private static let currentFileName = "CURRENT"
    private static let overlayDirectoryName = "overlay"

    private struct BuiltIndexArtifacts {
        let documents: [IndexedDocument]
        let buckets: [PostingBucket]
    }

    static func save(_ index: SearchIndex, to fileURL: URL) throws {
        let indexDirectoryURL = normalizedIndexDirectory(from: fileURL, rootURL: index.rootURL)

        try FileLock.withExclusiveLock(at: indexDirectoryURL.appendingPathComponent("lock")) {
            try FileManager.default.createDirectory(
                at: indexDirectoryURL.appendingPathComponent(generationsDirectoryName, isDirectory: true),
                withIntermediateDirectories: true
            )

            if let sourceLocation = index.currentLocation(), sourceLocation.indexDirectoryURL == indexDirectoryURL {
                try writeCurrent(generationID: sourceLocation.generationID, to: indexDirectoryURL)
                return
            }

            let generationID = "\(IndexMetadata.timestampNow())"
            let tempGenerationURL = indexDirectoryURL
                .appendingPathComponent(generationsDirectoryName, isDirectory: true)
                .appendingPathComponent("tmp-\(UUID().uuidString)", isDirectory: true)
            let generationURL = indexDirectoryURL
                .appendingPathComponent(generationsDirectoryName, isDirectory: true)
                .appendingPathComponent(generationID, isDirectory: true)

            try FileManager.default.createDirectory(at: tempGenerationURL, withIntermediateDirectories: true)

            if let sourceLocation = index.currentLocation() {
                let sourceGenerationURL = sourceLocation.indexDirectoryURL
                    .appendingPathComponent(generationsDirectoryName, isDirectory: true)
                    .appendingPathComponent(sourceLocation.generationID, isDirectory: true)
                try copyGeneration(from: sourceGenerationURL, to: tempGenerationURL)
                try writeMetadata(index.metadata, to: tempGenerationURL.appendingPathComponent("meta.json"))
            } else {
                guard let buckets = index.memoryBuckets() else {
                    throw NSError(domain: "RecallKit", code: 10, userInfo: [NSLocalizedDescriptionKey: "Cannot persist an index without postings"])
                }

                var postingsData = Data()
                var lookupEntries: [LookupTableEntry] = []

                for bucket in buckets {
                    let encoded = PostingCodec.encode(bucket.documents)
                    let offset = UInt64(postingsData.count)
                    postingsData.append(encoded)
                    lookupEntries.append(
                        LookupTableEntry(
                            hash: bucket.hash,
                            offset: offset,
                            length: UInt32(encoded.count)
                        )
                    )
                }

                try postingsData.write(to: tempGenerationURL.appendingPathComponent("postings.bin"), options: .atomic)
                try BinaryLookupTable.write(entries: lookupEntries, to: tempGenerationURL.appendingPathComponent("lookup.bin"))
                try FileTableCodec.write(index.documents, to: tempGenerationURL.appendingPathComponent("files.bin"))

                let metadata = IndexMetadata(
                    version: index.metadata.version,
                    commitHash: index.metadata.commitHash,
                    fileCount: index.documents.count,
                    ngramCount: buckets.count,
                    timestamp: IndexMetadata.timestampNow(),
                    configuration: index.configuration,
                    overlayFileCount: index.metadata.overlayFileCount,
                    overlayNGramCount: index.metadata.overlayNGramCount,
                    tombstoneCount: index.metadata.tombstoneCount
                )
                try writeMetadata(metadata, to: tempGenerationURL.appendingPathComponent("meta.json"))
            }

            try FileManager.default.moveItem(at: tempGenerationURL, to: generationURL)
            try writeCurrent(generationID: generationID, to: indexDirectoryURL)
        }
    }

    static func load(from fileURL: URL, rootOverride: URL? = nil) throws -> SearchIndex {
        let location = try resolveLocation(from: fileURL, rootOverride: rootOverride)
        let metadata = try validatedMetadata(from: location.generationURL.appendingPathComponent("meta.json"))
        let documents = try FileTableCodec.read(from: location.generationURL.appendingPathComponent("files.bin"))
        let binaryStore = try loadBinaryStore(from: location.generationURL)
        let overlayStorage = try loadOverlay(from: location.generationURL, baseDocumentCount: documents.count)

        return SearchIndex(
            rootURL: location.rootURL,
            configuration: metadata.configuration,
            documents: documents,
            binaryStore: binaryStore,
            metadata: metadata,
            persistedLocation: PersistedIndexLocation(
                indexDirectoryURL: location.indexDirectoryURL,
                generationID: location.generationID
            ),
            overlayStorage: overlayStorage
        )
    }

    static func update(at rootURL: URL, configuration: IndexConfiguration, indexDirectoryURL: URL? = nil) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        let resolvedIndexDirectory = normalizedIndexDirectory(
            from: indexDirectoryURL ?? standardizedRoot,
            rootURL: standardizedRoot
        )

        try FileLock.withExclusiveLock(at: resolvedIndexDirectory.appendingPathComponent("lock")) {
            let location = try resolveLocation(from: resolvedIndexDirectory, rootOverride: standardizedRoot)
            let metadataURL = location.generationURL.appendingPathComponent("meta.json")
            let metadata = try validatedMetadata(from: metadataURL)

            guard metadata.configuration == configuration else {
                throw NSError(
                    domain: "RecallKit",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Index configuration changed; rebuild required"]
                )
            }

            let baseDocuments = try FileTableCodec.read(from: location.generationURL.appendingPathComponent("files.bin"))
            let crawler = DirectoryCrawler(configuration: configuration)
            let currentFiles = try crawler.collectFiles(at: standardizedRoot)
            var currentByRelativePath = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.relativePath(from: standardizedRoot), $0) })
            var tombstones: [UInt32] = []
            var filesToIndex: [URL] = []

            for document in baseDocuments {
                guard let fileURL = currentByRelativePath.removeValue(forKey: document.relativePath) else {
                    tombstones.append(document.id)
                    continue
                }

                let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modifiedAtEpochSeconds = timestamp(from: resourceValues.contentModificationDate)
                let byteCount = resourceValues.fileSize ?? 0

                if modifiedAtEpochSeconds != document.modifiedAtEpochSeconds || byteCount != document.byteCount {
                    tombstones.append(document.id)
                    filesToIndex.append(fileURL)
                }
            }

            filesToIndex.append(contentsOf: currentByRelativePath.values.sorted { $0.path < $1.path })
            let overlayURL = location.generationURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)

            if filesToIndex.isEmpty && tombstones.isEmpty {
                if FileManager.default.fileExists(atPath: overlayURL.path) {
                    try FileManager.default.removeItem(at: overlayURL)
                }

                let refreshedMetadata = IndexMetadata(
                    version: IndexMetadata.currentVersion,
                    commitHash: GitRepositoryInfo.currentCommitHash(at: standardizedRoot),
                    fileCount: metadata.fileCount,
                    ngramCount: metadata.ngramCount,
                    timestamp: IndexMetadata.timestampNow(),
                    configuration: metadata.configuration,
                    overlayFileCount: 0,
                    overlayNGramCount: 0,
                    tombstoneCount: 0
                )
                try writeMetadata(refreshedMetadata, to: metadataURL)
                return
            }

            let artifacts = try buildArtifacts(
                for: filesToIndex.sorted { $0.path < $1.path },
                rootURL: standardizedRoot,
                configuration: configuration,
                startingDocumentID: UInt32(baseDocuments.count)
            )
            let uniqueTombstones = Array(Set(tombstones)).sorted()
            try writeOverlay(artifacts: artifacts, tombstones: uniqueTombstones, to: overlayURL)

            let refreshedMetadata = IndexMetadata(
                version: IndexMetadata.currentVersion,
                commitHash: GitRepositoryInfo.currentCommitHash(at: standardizedRoot),
                fileCount: metadata.fileCount,
                ngramCount: metadata.ngramCount,
                timestamp: IndexMetadata.timestampNow(),
                configuration: metadata.configuration,
                overlayFileCount: artifacts.documents.count,
                overlayNGramCount: artifacts.buckets.count,
                tombstoneCount: uniqueTombstones.count
            )
            try writeMetadata(refreshedMetadata, to: metadataURL)
        }
    }

    static func defaultIndexDirectory(for rootURL: URL) -> URL {
        rootURL.standardizedFileURL.appendingPathComponent(indexDirectoryName, isDirectory: true)
    }

    private struct ResolvedLocation {
        let rootURL: URL
        let indexDirectoryURL: URL
        let generationURL: URL
        let generationID: String
    }

    private static func normalizedIndexDirectory(from fileURL: URL, rootURL: URL) -> URL {
        let standardized = fileURL.standardizedFileURL

        if standardized.lastPathComponent == indexDirectoryName || standardized.pathExtension == "frg" {
            return standardized
        }

        return rootURL.standardizedFileURL.appendingPathComponent(indexDirectoryName, isDirectory: true)
    }

    private static func resolveLocation(from fileURL: URL, rootOverride: URL?) throws -> ResolvedLocation {
        let standardized = fileURL.standardizedFileURL
        let fileManager = FileManager.default
        let indexDirectoryURL: URL
        let rootURL: URL

        if fileManager.fileExists(atPath: standardized.appendingPathComponent(currentFileName).path) {
            indexDirectoryURL = standardized
            rootURL = rootOverride?.standardizedFileURL
                ?? (standardized.lastPathComponent == indexDirectoryName
                    ? standardized.deletingLastPathComponent()
                    : standardized)
        } else {
            let nestedIndexDirectory = standardized.appendingPathComponent(indexDirectoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: nestedIndexDirectory.appendingPathComponent(currentFileName).path) else {
                throw NSError(domain: "RecallKit", code: 11, userInfo: [NSLocalizedDescriptionKey: "No persisted index found at \(standardized.path)"])
            }

            indexDirectoryURL = nestedIndexDirectory
            rootURL = rootOverride?.standardizedFileURL ?? standardized
        }

        let generationID = try String(contentsOf: indexDirectoryURL.appendingPathComponent(currentFileName), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let generationURL = indexDirectoryURL
            .appendingPathComponent(generationsDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)

        return ResolvedLocation(
            rootURL: rootURL,
            indexDirectoryURL: indexDirectoryURL,
            generationURL: generationURL,
            generationID: generationID
        )
    }

    private static func writeCurrent(generationID: String, to indexDirectoryURL: URL) throws {
        let tmpURL = indexDirectoryURL.appendingPathComponent("\(currentFileName).tmp")
        let currentURL = indexDirectoryURL.appendingPathComponent(currentFileName)
        try generationID.write(to: tmpURL, atomically: true, encoding: .utf8)

        if FileManager.default.fileExists(atPath: currentURL.path) {
            try FileManager.default.removeItem(at: currentURL)
        }

        try FileManager.default.moveItem(at: tmpURL, to: currentURL)
    }

    private static func writeMetadata(_ metadata: IndexMetadata, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func readMetadata(from fileURL: URL) throws -> IndexMetadata {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(IndexMetadata.self, from: data)
    }

    private static func validatedMetadata(from fileURL: URL) throws -> IndexMetadata {
        let metadata = try readMetadata(from: fileURL)
        guard metadata.version == IndexMetadata.currentVersion else {
            throw NSError(
                domain: "RecallKit",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Index format version \(metadata.version) is incompatible; rebuild required"]
            )
        }

        return metadata
    }

    private static func copyGeneration(from sourceURL: URL, to targetURL: URL) throws {
        let fileManager = FileManager.default

        for fileName in ["meta.json", "postings.bin", "lookup.bin", "files.bin"] {
            let sourceFile = sourceURL.appendingPathComponent(fileName)
            let targetFile = targetURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: targetFile.path) {
                try fileManager.removeItem(at: targetFile)
            }
            try fileManager.copyItem(at: sourceFile, to: targetFile)
        }

        let sourceOverlayURL = sourceURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)
        let targetOverlayURL = targetURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)
        if fileManager.fileExists(atPath: sourceOverlayURL.path) {
            if fileManager.fileExists(atPath: targetOverlayURL.path) {
                try fileManager.removeItem(at: targetOverlayURL)
            }
            try fileManager.copyItem(at: sourceOverlayURL, to: targetOverlayURL)
        }
    }

    private static func loadBinaryStore(from directoryURL: URL) throws -> BinaryPostingsStore {
        let lookupData = try Data(contentsOf: directoryURL.appendingPathComponent("lookup.bin"), options: [.mappedIfSafe])
        let postingsData = try Data(contentsOf: directoryURL.appendingPathComponent("postings.bin"), options: [.mappedIfSafe])
        return BinaryPostingsStore(
            lookupTable: try BinaryLookupTable(data: lookupData),
            postingsData: postingsData
        )
    }

    private static func loadOverlay(from generationURL: URL, baseDocumentCount: Int) throws -> OverlaySearchStorage? {
        let overlayURL = generationURL.appendingPathComponent(overlayDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: overlayURL.path) else {
            return nil
        }

        let binaryStore = try loadBinaryStore(from: overlayURL)
        let documents = try FileTableCodec.read(from: overlayURL.appendingPathComponent("files.bin")).map { document in
            IndexedDocument(
                id: UInt32(baseDocumentCount) &+ document.id,
                relativePath: document.relativePath,
                byteCount: document.byteCount,
                modifiedAtEpochSeconds: document.modifiedAtEpochSeconds
            )
        }

        return OverlaySearchStorage(
            documents: documents,
            storage: .binary(binaryStore),
            tombstones: Set(try TombstoneCodec.read(from: overlayURL.appendingPathComponent("tombstones.bin")))
        )
    }

    private static func buildArtifacts(
        for fileURLs: [URL],
        rootURL: URL,
        configuration: IndexConfiguration,
        startingDocumentID: UInt32
    ) throws -> BuiltIndexArtifacts {
        let extractor = SparseNGramExtractor(maxNGramLength: configuration.maxNGramLength)
        var documents: [IndexedDocument] = []
        var postingSets: [UInt64: Set<UInt32>] = [:]

        for fileURL in fileURLs {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let documentID = startingDocumentID &+ UInt32(documents.count)
            let modifiedAtEpochSeconds = timestamp(from: resourceValues.contentModificationDate)
            let byteCount = resourceValues.fileSize ?? data.count

            documents.append(
                IndexedDocument(
                    id: documentID,
                    relativePath: fileURL.relativePath(from: rootURL),
                    byteCount: byteCount,
                    modifiedAtEpochSeconds: modifiedAtEpochSeconds
                )
            )

            let hashes = extractor.extractHashes(from: data)
            for hash in hashes {
                postingSets[hash, default: []].insert(documentID)
            }
        }

        let buckets = postingSets.keys.sorted().map { hash in
            PostingBucket(hash: hash, documents: postingSets[hash, default: []].sorted())
        }

        return BuiltIndexArtifacts(documents: documents, buckets: buckets)
    }

    private static func writeOverlay(artifacts: BuiltIndexArtifacts, tombstones: [UInt32], to overlayURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryOverlayURL = overlayURL.deletingLastPathComponent().appendingPathComponent("\(overlayDirectoryName).tmp-\(UUID().uuidString)", isDirectory: true)

        if fileManager.fileExists(atPath: temporaryOverlayURL.path) {
            try fileManager.removeItem(at: temporaryOverlayURL)
        }

        try fileManager.createDirectory(at: temporaryOverlayURL, withIntermediateDirectories: true)

        var postingsData = Data()
        var lookupEntries: [LookupTableEntry] = []

        for bucket in artifacts.buckets {
            let encoded = PostingCodec.encode(bucket.documents)
            let offset = UInt64(postingsData.count)
            postingsData.append(encoded)
            lookupEntries.append(
                LookupTableEntry(
                    hash: bucket.hash,
                    offset: offset,
                    length: UInt32(encoded.count)
                )
            )
        }

        try postingsData.write(to: temporaryOverlayURL.appendingPathComponent("postings.bin"), options: .atomic)
        try BinaryLookupTable.write(entries: lookupEntries, to: temporaryOverlayURL.appendingPathComponent("lookup.bin"))

        let overlayDocuments = artifacts.documents.enumerated().map { offset, document in
            IndexedDocument(
                id: UInt32(offset),
                relativePath: document.relativePath,
                byteCount: document.byteCount,
                modifiedAtEpochSeconds: document.modifiedAtEpochSeconds
            )
        }
        try FileTableCodec.write(overlayDocuments, to: temporaryOverlayURL.appendingPathComponent("files.bin"))
        try TombstoneCodec.write(tombstones, to: temporaryOverlayURL.appendingPathComponent("tombstones.bin"))

        if fileManager.fileExists(atPath: overlayURL.path) {
            try fileManager.removeItem(at: overlayURL)
        }

        try fileManager.moveItem(at: temporaryOverlayURL, to: overlayURL)
    }

    private static func timestamp(from date: Date?) -> UInt64 {
        date.map { UInt64(max(0, Int64($0.timeIntervalSince1970.rounded()))) } ?? 0
    }
}