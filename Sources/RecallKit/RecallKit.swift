import Foundation

/// Top-level namespace for building, querying, and benchmarking RecallKit indexes.
public enum RecallKit {
	/// Creates the actor-based record index service used by app memory and local-record integrations.
	public static func makeIndexService(
		configuration: RecordIndexServiceConfiguration = .default,
		snapshotProvider: (any RecordSnapshotProvider)? = nil
	) -> RecallKitIndexService {
		RecallKitIndexService(configuration: configuration, snapshotProvider: snapshotProvider)
	}

	public static func buildIndex(
		at rootURL: URL,
		configuration: IndexConfiguration = .default
	) throws -> SearchIndex {
		let standardizedRoot = rootURL.standardizedFileURL
		let crawler = DirectoryCrawler(configuration: configuration)
		let extractor = SparseNGramExtractor(maxNGramLength: configuration.maxNGramLength)
		let fileURLs = try crawler.collectFiles(at: standardizedRoot)

		var documents: [IndexedDocument] = []
		var postingSets: [UInt64: Set<UInt32>] = [:]

		for fileURL in fileURLs {
			let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
			let documentID = UInt32(documents.count)
			let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
			let modifiedAtEpochSeconds = values.contentModificationDate.map { date in
				UInt64(max(0, Int64(date.timeIntervalSince1970.rounded())))
			} ?? 0

			documents.append(
				IndexedDocument(
					id: documentID,
					relativePath: fileURL.relativePath(from: standardizedRoot),
					byteCount: data.count,
					modifiedAtEpochSeconds: modifiedAtEpochSeconds
				)
			)

			let hashes = extractor.extractHashes(from: data)
			for hash in hashes {
				postingSets[hash, default: []].insert(documentID)
			}
		}

		let postingLookup = postingSets.mapValues { $0.sorted() }
		let metadata = IndexMetadata(
			commitHash: GitRepositoryInfo.currentCommitHash(at: standardizedRoot),
			fileCount: documents.count,
			ngramCount: postingLookup.count,
			configuration: configuration
		)

		return SearchIndex(
			rootURL: standardizedRoot,
			configuration: configuration,
			documents: documents,
			postingLookup: postingLookup,
			metadata: metadata
		)
	}

	@discardableResult
	public static func createIndex(
		at rootURL: URL,
		configuration: IndexConfiguration = .default,
		indexDirectoryURL: URL? = nil
	) throws -> SearchIndex {
		let index = try buildIndex(at: rootURL, configuration: configuration)
		let targetDirectory = indexDirectoryURL ?? IndexPersistence.defaultIndexDirectory(for: rootURL.standardizedFileURL)
		try saveIndex(index, to: targetDirectory)
		return try loadIndex(from: rootURL)
	}

	@discardableResult
	public static func updateIndex(
		at rootURL: URL,
		configuration: IndexConfiguration = .default,
		indexDirectoryURL: URL? = nil
	) throws -> SearchIndex {
		let standardizedRoot = rootURL.standardizedFileURL
		let targetDirectory = indexDirectoryURL ?? IndexPersistence.defaultIndexDirectory(for: standardizedRoot)

		do {
			try IndexPersistence.update(at: standardizedRoot, configuration: configuration, indexDirectoryURL: targetDirectory)
		} catch let error as NSError where error.domain == "RecallKit" && [11, 12, 13].contains(error.code) {
			return try createIndex(at: standardizedRoot, configuration: configuration, indexDirectoryURL: targetDirectory)
		}

		return try loadIndex(from: standardizedRoot)
	}

	public static func openIndex(at rootURL: URL) throws -> SearchIndex {
		try loadIndex(from: rootURL)
	}

	public static func indexStatus(at rootURL: URL) throws -> IndexStatus {
		let index = try loadIndex(from: rootURL)
		guard let status = index.currentStatus() else {
			throw NSError(domain: "RecallKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Index is not persisted"])
		}

		return status
	}

	public static func saveIndex(_ index: SearchIndex, to fileURL: URL) throws {
		try IndexPersistence.save(index, to: fileURL)
	}

	public static func loadIndex(from fileURL: URL, rootOverride: URL? = nil) throws -> SearchIndex {
		try IndexPersistence.load(from: fileURL, rootOverride: rootOverride)
	}

	public static func search(
		_ pattern: String,
		using index: SearchIndex,
		configuration: SearchConfiguration = .default
	) throws -> SearchReport {
		try Searcher.search(pattern, using: index, configuration: configuration)
	}

	public static func naiveSearch(
		_ pattern: String,
		at rootURL: URL,
		configuration: SearchConfiguration = .default,
		indexConfiguration: IndexConfiguration = .default
	) throws -> SearchReport {
		let standardizedRoot = rootURL.standardizedFileURL
		let crawler = DirectoryCrawler(configuration: indexConfiguration)
		let files = try crawler.collectFiles(at: standardizedRoot)
		return try Searcher.naiveSearch(
			pattern,
			files: files,
			rootURL: standardizedRoot,
			configuration: configuration
		)
	}

	public static func benchmark(
		pattern: String,
		at rootURL: URL,
		indexConfiguration: IndexConfiguration = .default,
		searchConfiguration: SearchConfiguration = .default
	) throws -> BenchmarkSnapshot {
		let clock = ContinuousClock()

		let buildStart = clock.now
		let index = try buildIndex(at: rootURL, configuration: indexConfiguration)
		let buildTime = buildStart.duration(to: clock.now)

		let indexedSearchStart = clock.now
		let indexedReport = try search(pattern, using: index, configuration: searchConfiguration)
		let indexedSearchTime = indexedSearchStart.duration(to: clock.now)

		let naiveSearchStart = clock.now
		let naiveReport = try naiveSearch(
			pattern,
			at: rootURL,
			configuration: searchConfiguration,
			indexConfiguration: indexConfiguration
		)
		let naiveSearchTime = naiveSearchStart.duration(to: clock.now)

		return BenchmarkSnapshot(
			fileCount: index.documents.count,
			buildMilliseconds: buildTime.milliseconds,
			indexedSearchMilliseconds: indexedSearchTime.milliseconds,
			naiveSearchMilliseconds: naiveSearchTime.milliseconds,
			candidateCount: indexedReport.candidateCount,
			indexedMatchCount: indexedReport.matches.count,
			naiveMatchCount: naiveReport.matches.count
		)
	}

	public static func benchmark(
		records: [IndexedRecord],
		query: RecordSearchQuery,
		configuration: RecordIndexServiceConfiguration = .default,
		mode: RecordBenchmarkMode = .rebuildAndQuery,
		progress: (@MainActor (RecordBenchmarkProgress) -> Void)? = nil
	) async throws -> RecordBenchmarkSnapshot {
		let clock = ContinuousClock()
		let totalStart = clock.now

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .preparing,
					engine: .recallKit,
					message: "Creating benchmark service for \(records.count) records.",
					recordCount: records.count
				)
			)
		}

		let service = makeIndexService(configuration: configuration)
		let comparisonUnits = makeBenchmarkUnits(from: records)
		let corpusSignature = benchmarkCorpusSignature(records: records)
		let comparisonStorageRoot = try benchmarkStorageRoot(for: configuration)

		let benchmarkStatus: RecordIndexStatus
		let buildTime: Duration

		switch mode {
		case .rebuildAndQuery:
			if let progress {
				await progress(
					RecordBenchmarkProgress(
						phase: .buildingIndex,
						engine: .recallKit,
						message: "Building persisted sparse index.",
						recordCount: records.count
					)
				)
			}

			let buildStart = clock.now
			let buildResult = try await service.replaceAll(with: records)
			buildTime = buildStart.duration(to: clock.now)
			benchmarkStatus = buildResult.status

			if let progress {
				await progress(
					RecordBenchmarkProgress(
						phase: .buildingIndex,
						engine: .recallKit,
						message: "Built index with \(buildResult.status.chunkCount) chunks and \(buildResult.status.ngramCount) n-grams.",
						recordCount: records.count,
						elapsedMilliseconds: buildTime.milliseconds,
						chunkCount: buildResult.status.chunkCount,
						ngramCount: buildResult.status.ngramCount
					)
				)
			}

		case .reuseExistingIndex:
			guard configuration.storageLocation != .ephemeral else {
				throw NSError(
					domain: "RecallKit",
					code: 61,
					userInfo: [NSLocalizedDescriptionKey: "Query-only benchmark mode requires a persistent storage location"]
				)
			}

			if let progress {
				await progress(
					RecordBenchmarkProgress(
						phase: .loadingIndex,
						engine: .recallKit,
						message: "Loading existing persisted index.",
						recordCount: records.count
					)
				)
			}

			let loadStart = clock.now
			let status = try await service.bootstrap()
			let loadTime = loadStart.duration(to: clock.now)
			guard status.recordCount > 0 || records.isEmpty else {
				throw NSError(
					domain: "RecallKit",
					code: 62,
					userInfo: [NSLocalizedDescriptionKey: "No existing benchmark index found. Run a rebuild benchmark first."]
				)
			}

			benchmarkStatus = status
			buildTime = .zero

			if let progress {
				await progress(
					RecordBenchmarkProgress(
						phase: .loadingIndex,
						engine: .recallKit,
						message: "Loaded existing index with \(status.chunkCount) chunks and \(status.ngramCount) n-grams.",
						recordCount: records.count,
						elapsedMilliseconds: loadTime.milliseconds,
						chunkCount: status.chunkCount,
						ngramCount: status.ngramCount
					)
				)
			}
		}

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .indexedSearch,
					engine: .recallKit,
					message: "Running indexed search.",
					recordCount: records.count,
					chunkCount: benchmarkStatus.chunkCount,
					ngramCount: benchmarkStatus.ngramCount
				)
			)
		}

		let indexedSearchStart = clock.now
		let indexedReport = try await service.search(query)
		let indexedSearchTime = indexedSearchStart.duration(to: clock.now)

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .indexedSearch,
					engine: .recallKit,
					message: "Indexed search checked \(indexedReport.candidateChunkCount) candidate chunks and matched \(indexedReport.matchedRecordCount) records.",
					recordCount: records.count,
					elapsedMilliseconds: indexedSearchTime.milliseconds,
					chunkCount: benchmarkStatus.chunkCount,
					ngramCount: benchmarkStatus.ngramCount,
					candidateChunkCount: indexedReport.candidateChunkCount,
					matchedRecordCount: indexedReport.matchedRecordCount
				)
			)
		}

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .naiveSearch,
					engine: .naiveScan,
					message: "Running naive scan across all records.",
					recordCount: records.count
				)
			)
		}

		let naiveSearchStart = clock.now
		let naiveMatchedRecordCount = try naiveRecordSearchCount(records: records, query: query)
		let naiveSearchTime = naiveSearchStart.duration(to: clock.now)

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .naiveSearch,
					engine: .naiveScan,
					message: "Naive scan matched \(naiveMatchedRecordCount) records.",
					recordCount: records.count,
					elapsedMilliseconds: naiveSearchTime.milliseconds,
					matchedRecordCount: naiveMatchedRecordCount
				)
			)
		}

		var results: [RecordBenchmarkResult] = [
			RecordBenchmarkResult(
				engine: .recallKit,
				buildMilliseconds: buildTime.milliseconds,
				queryMilliseconds: indexedSearchTime.milliseconds,
				matchedRecordCount: indexedReport.matchedRecordCount,
				available: true,
				note: mode == .reuseExistingIndex ? "Reused persisted RecallKit index." : "Rebuilt persisted RecallKit index."
			),
			RecordBenchmarkResult(
				engine: .naiveScan,
				buildMilliseconds: nil,
				queryMilliseconds: naiveSearchTime.milliseconds,
				matchedRecordCount: naiveMatchedRecordCount,
				available: true,
				note: "Direct NSRegularExpression scan over all searchable record fields."
			)
		]

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .sqliteFTS5Build,
					engine: .sqliteFTS5,
					message: "Preparing SQLite FTS5 comparison.",
					recordCount: records.count
				)
			)
		}
		let sqliteFTS5Result = makeSQLiteFTS5Result(
			units: comparisonUnits,
			query: query,
			mode: mode,
			storageRoot: comparisonStorageRoot,
			corpusSignature: corpusSignature
		)
		results.append(sqliteFTS5Result)
		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .sqliteFTS5Build,
					engine: .sqliteFTS5,
					message: sqliteFTS5Result.note ?? "SQLite FTS5 comparison ready.",
					recordCount: records.count,
					elapsedMilliseconds: sqliteFTS5Result.buildMilliseconds
				)
			)
			await progress(
				RecordBenchmarkProgress(
					phase: .sqliteFTS5Search,
					engine: .sqliteFTS5,
					message: sqliteFTS5Result.available
						? "SQLite FTS5 matched \(sqliteFTS5Result.matchedRecordCount ?? 0) records."
						: (sqliteFTS5Result.note ?? "SQLite FTS5 comparison unavailable."),
					recordCount: records.count,
					elapsedMilliseconds: sqliteFTS5Result.queryMilliseconds,
					matchedRecordCount: sqliteFTS5Result.matchedRecordCount
				)
			)
		}

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .coreDataBuild,
					engine: .coreDataContains,
					message: "Preparing Core Data comparison.",
					recordCount: records.count
				)
			)
		}
		let coreDataResult = makeCoreDataResult(
			units: comparisonUnits,
			query: query,
			mode: mode,
			storageRoot: comparisonStorageRoot,
			corpusSignature: corpusSignature
		)
		results.append(coreDataResult)
		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .coreDataBuild,
					engine: .coreDataContains,
					message: coreDataResult.note ?? "Core Data comparison ready.",
					recordCount: records.count,
					elapsedMilliseconds: coreDataResult.buildMilliseconds
				)
			)
			await progress(
				RecordBenchmarkProgress(
					phase: .coreDataSearch,
					engine: .coreDataContains,
					message: coreDataResult.available
						? "Core Data matched \(coreDataResult.matchedRecordCount ?? 0) records."
						: (coreDataResult.note ?? "Core Data comparison unavailable."),
					recordCount: records.count,
					elapsedMilliseconds: coreDataResult.queryMilliseconds,
					matchedRecordCount: coreDataResult.matchedRecordCount
				)
			)
		}

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .coreSpotlightBuild,
					engine: .coreSpotlight,
					message: "Preparing Core Spotlight comparison.",
					recordCount: records.count
				)
			)
		}
		let coreSpotlightResult = await makeCoreSpotlightResult(
			units: comparisonUnits,
			query: query,
			mode: mode,
			storageRoot: comparisonStorageRoot,
			corpusSignature: corpusSignature
		)
		results.append(coreSpotlightResult)
		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .coreSpotlightBuild,
					engine: .coreSpotlight,
					message: coreSpotlightResult.note ?? "Core Spotlight comparison ready.",
					recordCount: records.count,
					elapsedMilliseconds: coreSpotlightResult.buildMilliseconds
				)
			)
			await progress(
				RecordBenchmarkProgress(
					phase: .coreSpotlightSearch,
					engine: .coreSpotlight,
					message: coreSpotlightResult.available
						? "Core Spotlight matched \(coreSpotlightResult.matchedRecordCount ?? 0) records."
						: (coreSpotlightResult.note ?? "Core Spotlight comparison unavailable."),
					recordCount: records.count,
					elapsedMilliseconds: coreSpotlightResult.queryMilliseconds,
					matchedRecordCount: coreSpotlightResult.matchedRecordCount
				)
			)
		}

		let totalTime = totalStart.duration(to: clock.now)

		if let progress {
			await progress(
				RecordBenchmarkProgress(
					phase: .completed,
					engine: .recallKit,
					message: "Benchmark completed.",
					recordCount: records.count,
					elapsedMilliseconds: totalTime.milliseconds,
					chunkCount: benchmarkStatus.chunkCount,
					ngramCount: benchmarkStatus.ngramCount,
					candidateChunkCount: indexedReport.candidateChunkCount,
					matchedRecordCount: indexedReport.matchedRecordCount
				)
			)
		}

		return RecordBenchmarkSnapshot(
			mode: mode,
			recordCount: records.count,
			candidateChunkCount: indexedReport.candidateChunkCount,
			results: results
		)
	}
}

private extension Duration {
	var milliseconds: Double {
		let parts = components
		let millisecondsFromSeconds = Double(parts.seconds) * 1_000
		let millisecondsFromAttoseconds = Double(parts.attoseconds) / 1_000_000_000_000_000.0
		return millisecondsFromSeconds + millisecondsFromAttoseconds
	}
}

private func naiveRecordSearchCount(records: [IndexedRecord], query: RecordSearchQuery) throws -> Int {
	let caseInsensitive = query.caseInsensitive || (query.smartCase && !query.text.contains(where: \ .isUppercase))
	let regexPattern = query.mode == .literal ? NSRegularExpression.escapedPattern(for: query.text) : query.text
	let regex = try NSRegularExpression(
		pattern: regexPattern,
		options: caseInsensitive ? [.caseInsensitive] : []
	)

	return records.filter { record in
		(query.collections.isEmpty || query.collections.contains(record.collection))
			&& record.searchableFields.contains { field, value in
				(query.fields.isEmpty || query.fields.contains(field))
					&& query.requiredTags.isSubset(of: Set(record.tags))
					&& regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
			}
	}.count
}

enum GitRepositoryInfo {
	static func currentCommitHash(at rootURL: URL) -> String? {
		#if os(macOS)
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["git", "rev-parse", "HEAD"]
		process.currentDirectoryURL = rootURL

		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = Pipe()

		do {
			try process.run()
			process.waitUntilExit()
			guard process.terminationStatus == 0 else {
				return nil
			}

			let data = pipe.fileHandleForReading.readDataToEndOfFile()
			let commitHash = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
			return commitHash.isEmpty ? nil : commitHash
		} catch {
			return nil
		}
		#else
		return nil
		#endif
	}
}
