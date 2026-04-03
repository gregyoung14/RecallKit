import Foundation
import Testing
@testable import RecallKit

@Test("Sparse extraction is deterministic")
func sparseExtractionIsDeterministic() {
    let extractor = SparseNGramExtractor(maxNGramLength: 8)
    let firstPass = extractor.debugExtractStrings(from: "struct SearchEngine")
    let secondPass = extractor.debugExtractStrings(from: "struct SearchEngine")

    #expect(firstPass == secondPass)
    #expect(firstPass.contains("st"))
    #expect(firstPass.contains(where: { $0.count >= 3 }))
}

@Test("Weight table tracks common and rare byte pairs")
func weightTableTracksCommonAndRarePairs() {
    let table = WeightTable.default

    #expect(table.weight(UInt8(ascii: "t"), UInt8(ascii: "h")) < 30)
    #expect((30...50).contains(table.weight(UInt8(ascii: "q"), UInt8(ascii: "z"))))
    #expect(table.weight(UInt8(ascii: "/"), UInt8(ascii: "q")) > 100)
    #expect((80...150).contains(table.weight(UInt8(ascii: "e"), UInt8(ascii: "B"))))
    #expect(table.weight(UInt8(ascii: " "), UInt8(ascii: " ")) < 10)
}

@Test("Index build and regex search find expected files")
func indexAndSearchFindExpectedMatches() throws {
    try withTemporaryDirectory { directoryURL in
        try writeCorpus(
            into: directoryURL,
            files: [
                "Sources/App/SearchEngine.swift": """
                struct SearchEngine {
                    let marker = \"sparse-index\"
                }
                """,
                "Sources/App/Parser.swift": "enum Parser { }",
                "README.md": "SearchEngine ships as an example"
            ]
        )

        let index = try RecallKit.buildIndex(at: directoryURL)
        let report = try RecallKit.search("Search.*Engine", using: index)

        #expect(report.candidateCount > 0)
        #expect(report.matches.contains(where: { $0.relativePath == "README.md" }))
        #expect(report.matches.contains(where: { $0.relativePath == "Sources/App/SearchEngine.swift" }))
    }
}

@Test("Query planner handles alternation and grouped concatenation")
func queryPlannerHandlesAlternationAndGroupedConcatenation() throws {
    try withTemporaryDirectory { directoryURL in
        try writeCorpus(
            into: directoryURL,
            files: [
                "Sources/App/Engine.swift": "struct SearchEngine { let token = 1 }",
                "Sources/App/Parser.swift": "struct SearchParser { let token = 2 }",
                "Sources/App/Noise.swift": "struct TotallyDifferent { let token = 3 }"
            ]
        )

        let index = try RecallKit.buildIndex(at: directoryURL)
        let report = try RecallKit.search("Search(Engine|Parser)", using: index)
        let paths = Set(report.matches.map(\ .relativePath))

        #expect(report.candidateCount < index.documentCount)
        #expect(paths.contains("Sources/App/Engine.swift"))
        #expect(paths.contains("Sources/App/Parser.swift"))
        #expect(!paths.contains("Sources/App/Noise.swift"))
    }
}

@Test("Query planner keeps mandatory literals around character classes and quantifiers")
func queryPlannerUsesMandatoryLiteralsAroundCharacterClassesAndQuantifiers() throws {
    try withTemporaryDirectory { directoryURL in
        try writeCorpus(
            into: directoryURL,
            files: [
                "Sources/App/Match.swift": "let value = \"Search1Engine\"",
                "Sources/App/Noise.swift": "let value = \"SearchZZEngine\"",
                "Sources/App/Other.swift": "let value = \"parser\""
            ]
        )

        let index = try RecallKit.buildIndex(at: directoryURL)
        let report = try RecallKit.search("Search[0-9]+Engine", using: index)

        #expect(report.candidateCount < index.documentCount)
        #expect(report.matches.count == 1)
        #expect(report.matches.first?.relativePath == "Sources/App/Match.swift")
    }
}

@Test("Query planner emits lookup plans and propagates scan-all branches")
func queryPlannerEmitsLookupPlansAndScanAllBranches() {
    let planner = RegexQueryPlanner()

    #expect(planner.plan(for: "ab") == .lookup(StableHasher.hash(bytes: Array("ab".utf8))))
    #expect(planner.plan(for: "a|foo") == .scanAll)

    guard case let .and(children) = planner.plan(for: "foo.*bar") else {
        Issue.record("Expected foo.*bar to decompose into an AND plan")
        return
    }

    #expect(children.count == 2)
}

@Test("Persisted indexes round-trip cleanly")
func persistedIndexesRoundTrip() throws {
    try withTemporaryDirectory { directoryURL in
        try writeCorpus(
            into: directoryURL,
            files: [
                "Sources/App/SearchEngine.swift": "let token = \"sparse-index\"",
                "Sources/App/Other.swift": "let token = \"other\""
            ]
        )

        let persisted = try RecallKit.createIndex(at: directoryURL)
        let indexDirectoryURL = directoryURL.appendingPathComponent(".frg")
        let currentGeneration = try String(contentsOf: indexDirectoryURL.appendingPathComponent("CURRENT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(FileManager.default.fileExists(atPath: indexDirectoryURL.appendingPathComponent("CURRENT").path))
        #expect(FileManager.default.fileExists(atPath: indexDirectoryURL.appendingPathComponent("generations/\(currentGeneration)/meta.json").path))
        #expect(FileManager.default.fileExists(atPath: indexDirectoryURL.appendingPathComponent("generations/\(currentGeneration)/postings.bin").path))
        #expect(FileManager.default.fileExists(atPath: indexDirectoryURL.appendingPathComponent("generations/\(currentGeneration)/lookup.bin").path))
        #expect(FileManager.default.fileExists(atPath: indexDirectoryURL.appendingPathComponent("generations/\(currentGeneration)/files.bin").path))

        let loaded = try RecallKit.loadIndex(from: directoryURL)
        let report = try RecallKit.search("sparse-index", using: loaded)
        let status = try RecallKit.indexStatus(at: directoryURL)

        #expect(loaded.documentCount == persisted.documentCount)
        #expect(report.matches.count == 1)
        #expect(report.matches.first?.relativePath == "Sources/App/SearchEngine.swift")
        #expect(status.metadata.fileCount == 2)
        #expect(status.metadata.ngramCount > 0)
    }
}

@Test("Update writes an overlay for the current generation")
func updateWritesAnOverlayForTheCurrentGeneration() throws {
    try withTemporaryDirectory { directoryURL in
        try writeCorpus(
            into: directoryURL,
            files: [
                "Sources/App/Initial.swift": "let marker = \"before\""
            ]
        )

        _ = try RecallKit.createIndex(at: directoryURL)
        let indexDirectoryURL = directoryURL.appendingPathComponent(".frg")
        let generation = try String(contentsOf: indexDirectoryURL.appendingPathComponent("CURRENT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        try writeCorpus(
            into: directoryURL,
            files: [
                "Sources/App/Initial.swift": "let marker = \"after\"",
                "Sources/App/New.swift": "let token = \"sparse-index\""
            ]
        )

        _ = try RecallKit.updateIndex(at: directoryURL)
        let currentGeneration = try String(contentsOf: indexDirectoryURL.appendingPathComponent("CURRENT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let loaded = try RecallKit.openIndex(at: directoryURL)
        let beforeReport = try RecallKit.search("before", using: loaded)
        let afterReport = try RecallKit.search("after", using: loaded)
        let newFileReport = try RecallKit.search("sparse-index", using: loaded)
        let status = try RecallKit.indexStatus(at: directoryURL)
        let overlayDirectoryURL = indexDirectoryURL.appendingPathComponent("generations/\(generation)/overlay")

        #expect(generation == currentGeneration)
        #expect(FileManager.default.fileExists(atPath: overlayDirectoryURL.appendingPathComponent("postings.bin").path))
        #expect(FileManager.default.fileExists(atPath: overlayDirectoryURL.appendingPathComponent("lookup.bin").path))
        #expect(FileManager.default.fileExists(atPath: overlayDirectoryURL.appendingPathComponent("files.bin").path))
        #expect(FileManager.default.fileExists(atPath: overlayDirectoryURL.appendingPathComponent("tombstones.bin").path))
        #expect(loaded.documentCount == 2)
        #expect(beforeReport.matches.isEmpty)
        #expect(afterReport.matches.count == 1)
        #expect(afterReport.matches.first?.relativePath == "Sources/App/Initial.swift")
        #expect(newFileReport.matches.count == 1)
        #expect(newFileReport.matches.first?.relativePath == "Sources/App/New.swift")
        #expect(status.metadata.overlayFileCount == 2)
        #expect(status.metadata.tombstoneCount == 1)
    }
}

@Test("Benchmark snapshot compares indexed and naive results")
func benchmarkSnapshotComparesIndexedAndNaiveSearch() throws {
    try withTemporaryDirectory { directoryURL in
        var files: [String: String] = [:]

        for fileIndex in 0..<40 {
            let contents = (0..<25).map { lineIndex in
                if fileIndex == 17 && lineIndex == 12 {
                    return "let benchmarkNeedle = \"SearchEngine\""
                }
                return "let value\(lineIndex) = \"file-\(fileIndex)-line-\(lineIndex)\""
            }.joined(separator: "\n")

            files["Sources/Bench/File\(fileIndex).swift"] = contents
        }

        try writeCorpus(into: directoryURL, files: files)
        let snapshot = try RecallKit.benchmark(pattern: "SearchEngine", at: directoryURL)

        #expect(snapshot.fileCount == 40)
        #expect(snapshot.indexedMatchCount == snapshot.naiveMatchCount)
        #expect(snapshot.buildMilliseconds >= 0)
        #expect(snapshot.indexedSearchMilliseconds >= 0)
        #expect(snapshot.naiveSearchMilliseconds >= 0)
    }
}

@Test("Record index service upserts searches deletes and compacts")
func recordIndexServiceUpsertsSearchesDeletesAndCompacts() async throws {
    try await withTemporaryDirectoryAsync { directoryURL in
        let indexURL = directoryURL.appendingPathComponent("RecordIndex", isDirectory: true)
        let configuration = RecordIndexServiceConfiguration(
            storageLocation: .custom(indexURL),
            compactionThreshold: 10_000
        )
        let service = RecallKit.makeIndexService(configuration: configuration)

        let initialResult = try await service.upsert([
            IndexedRecord(
                id: "r1",
                collection: "messages",
                title: "Sparse indexing",
                body: "This chat memory uses sparse indexing for fast lookup.",
                tags: ["memory", "chat"],
                metadata: ["conversation": "alpha"]
            ),
            IndexedRecord(
                id: "r2",
                collection: "notes",
                body: "Project notes mention BackgroundTasks compaction for the index.",
                tags: ["notes"],
                metadata: ["project": "ios"]
            )
        ])

        #expect(initialResult.status.recordCount == 2)
        #expect(initialResult.status.chunkCount >= 2)

        let search = try await service.search(
            RecordSearchQuery(text: "sparse indexing", mode: .literal, collections: ["messages"])
        )
        #expect(search.matchedRecordCount == 1)
        #expect(search.hits.first?.recordID == "r1")

        _ = try await service.upsert([
            IndexedRecord(
                id: "r1",
                collection: "messages",
                title: "Sparse indexing",
                body: "This chat memory now uses hashed ngrams for recall.",
                tags: ["memory", "chat"],
                metadata: ["conversation": "alpha"]
            )
        ])

        let oldSearch = try await service.search(RecordSearchQuery(text: "fast lookup", mode: .literal, collections: ["messages"]))
        let newSearch = try await service.search(RecordSearchQuery(text: "hashed ngrams", mode: .literal, collections: ["messages"]))
        #expect(oldSearch.hits.isEmpty)
        #expect(newSearch.hits.first?.recordID == "r1")

        let deleteResult = try await service.delete(recordIDs: ["r2"], in: "notes")
        #expect(deleteResult.deletedRecordCount == 1)
        let deletedSearch = try await service.search(RecordSearchQuery(text: "BackgroundTasks", mode: .literal, collections: ["notes"]))
        #expect(deletedSearch.hits.isEmpty)

        let compacted = try await service.compact()
        #expect(compacted.status.overlayChunkCount == 0)
        #expect(compacted.status.tombstoneCount == 0)

        let reopened = RecallKit.makeIndexService(configuration: configuration)
        let reopenedStatus = try await reopened.bootstrap()
        let reopenedSearch = try await reopened.search(RecordSearchQuery(text: "hashed ngrams", mode: .literal, collections: ["messages"]))

        #expect(reopenedStatus.recordCount == 1)
        #expect(reopenedSearch.hits.first?.recordID == "r1")
    }
}

@Test("Record index service rebuilds from snapshot provider after corruption")
func recordIndexServiceRebuildsFromSnapshotProviderAfterCorruption() async throws {
    try await withTemporaryDirectoryAsync { directoryURL in
        let indexURL = directoryURL.appendingPathComponent("RecordIndex", isDirectory: true)
        let records = [
            IndexedRecord(
                id: "memo-1",
                collection: "memories",
                body: "A persisted memory about sparse indexing.",
                tags: ["memory"]
            )
        ]
        let provider = ClosureRecordSnapshotProvider { records }
        let configuration = RecordIndexServiceConfiguration(
            storageLocation: .custom(indexURL),
            recoveryStrategy: .rebuildFromSource,
            compactionThreshold: 10_000
        )

        let initialService = RecallKit.makeIndexService(configuration: configuration, snapshotProvider: provider)
        _ = try await initialService.replaceAll(with: records)

        let currentGeneration = try String(contentsOf: indexURL.appendingPathComponent("CURRENT"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataURL = indexURL.appendingPathComponent("generations/\(currentGeneration)/meta.json")
        try "{not valid json".write(to: metadataURL, atomically: true, encoding: .utf8)

        let recoveredService = RecallKit.makeIndexService(configuration: configuration, snapshotProvider: provider)
        let status = try await recoveredService.bootstrap()
        let search = try await recoveredService.search(RecordSearchQuery(text: "sparse indexing", mode: .literal, collections: ["memories"]))

        #expect(status.recordCount == 1)
        #expect(search.hits.first?.recordID == "memo-1")
    }
}

@Test("Record index service enforces memory budgets")
func recordIndexServiceEnforcesMemoryBudgets() async throws {
    try await withTemporaryDirectoryAsync { directoryURL in
        let configuration = RecordIndexServiceConfiguration(
            chunking: ChunkingConfiguration(maxChunkBytes: 256, overlapBytes: 0),
            memoryBudget: MemoryBudget(
                maxResidentChunkBytes: 512,
                maxMappedIndexBytes: 4 * 1024,
                maxCachedChunkCount: 1,
                maxChunkBytes: 256
            ),
            storageLocation: .custom(directoryURL.appendingPathComponent("RecordIndex", isDirectory: true))
        )
        let service = RecallKit.makeIndexService(configuration: configuration)
        let oversizedRecord = IndexedRecord(
            id: "big",
            collection: "messages",
            body: String(repeating: "chunk ", count: 200)
        )

        do {
            _ = try await service.upsert([oversizedRecord])
            Issue.record("Expected memory budget enforcement to reject oversized record indexing")
        } catch {
            #expect(error is RecordIndexPersistenceError)
        }
    }
}

@Test("Record benchmark can reuse an existing persisted index")
func recordBenchmarkCanReuseExistingIndex() async throws {
    try await withTemporaryDirectoryAsync { directoryURL in
        let indexURL = directoryURL.appendingPathComponent("BenchIndex", isDirectory: true)
        let records = [
            IndexedRecord(
                id: "msg-1",
                collection: "messages",
                title: "SearchEngine memory",
                body: "Sparse indexing keeps local app memory searchable.",
                tags: ["memory"]
            ),
            IndexedRecord(
                id: "msg-2",
                collection: "messages",
                body: "The actor-backed index supports fast lookup.",
                tags: ["memory"]
            )
        ]
        let query = RecordSearchQuery(text: "SearchEngine", mode: .literal, collections: ["messages"])
        let configuration = RecordIndexServiceConfiguration(
            storageLocation: .custom(indexURL),
            dataProtection: .none,
            compactionThreshold: 4_096
        )

        let rebuilt = try await RecallKit.benchmark(
            records: records,
            query: query,
            configuration: configuration,
            mode: .rebuildAndQuery
        )
        let reused = try await RecallKit.benchmark(
            records: records,
            query: query,
            configuration: configuration,
            mode: .reuseExistingIndex
        )

        #expect(rebuilt.mode == .rebuildAndQuery)
        #expect(reused.mode == .reuseExistingIndex)
        #expect(reused.buildMilliseconds == 0)
        #expect(reused.indexedMatchedRecordCount == rebuilt.indexedMatchedRecordCount)
        #expect(reused.naiveMatchedRecordCount == rebuilt.naiveMatchedRecordCount)
        #expect(Set(rebuilt.results.map(\.engine)) == Set(RecordBenchmarkEngine.allCases))
        #expect(Set(reused.results.map(\.engine)) == Set(RecordBenchmarkEngine.allCases))
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    defer {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    try body(directoryURL)
}

private func withTemporaryDirectoryAsync(_ body: (URL) async throws -> Void) async throws {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    defer {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    try await body(directoryURL)
}

private func writeCorpus(into rootURL: URL, files: [String: String]) throws {
    for (relativePath, contents) in files {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
