import Foundation
import SQLite3

#if canImport(CoreData)
@preconcurrency import CoreData
#endif

#if canImport(CoreSpotlight)
import CoreSpotlight
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct BenchmarkSearchUnit: Sendable, Hashable {
    let unitID: String
    let recordID: String
    let collection: String
    let field: String
    let text: String
    let tags: [String]
}

private struct BenchmarkCorpusMetadata: Codable {
    let schemaVersion: Int
    let corpusSignature: String
    let variant: String?
}

private struct BenchmarkPreparationResult {
    let buildMilliseconds: Double
    let note: String?
}

private enum BenchmarkComparisonError: LocalizedError {
    case invalidSQLiteDatabase(String)
    case coreSpotlightUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidSQLiteDatabase(message):
            return message
        case .coreSpotlightUnavailable:
            return "Core Spotlight indexing is unavailable on this device"
        }
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

func makeBenchmarkUnits(from records: [IndexedRecord]) -> [BenchmarkSearchUnit] {
    records.flatMap { record in
        record.searchableFields.map { field, value in
            BenchmarkSearchUnit(
                unitID: "\(record.collection)\u{001F}\(record.id)\u{001F}\(field)",
                recordID: record.id,
                collection: record.collection,
                field: field,
                text: value,
                tags: record.tags.sorted()
            )
        }
    }
}

func benchmarkCorpusSignature(records: [IndexedRecord]) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(records.reduce(into: 0) { partial, record in
        partial += record.id.utf8.count
        partial += record.collection.utf8.count
        partial += (record.title?.utf8.count ?? 0)
        partial += record.body.utf8.count
        partial += record.fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        partial += record.tags.reduce(0) { $0 + $1.utf8.count }
        partial += 64
    })

    func append(_ string: String) {
        bytes.append(contentsOf: string.utf8)
        bytes.append(0x1E)
    }

    for record in records {
        append(record.id)
        append(record.collection)
        append(record.title ?? "")
        append(record.body)
        append(String(record.updatedAtEpochSeconds))

        for key in record.fields.keys.sorted() {
            append(key)
            append(record.fields[key] ?? "")
        }

        for tag in record.tags.sorted() {
            append(tag)
        }
    }

    return String(StableHasher.hash(bytes: bytes), radix: 16)
}

private func benchmarkCaseInsensitive(_ query: RecordSearchQuery) -> Bool {
    query.caseInsensitive || (query.smartCase && !query.text.contains(where: \.isUppercase))
}

private func benchmarkTagString(_ tags: [String]) -> String {
    "|\(tags.sorted().joined(separator: "|"))|"
}

func benchmarkStorageRoot(for configuration: RecordIndexServiceConfiguration) throws -> URL? {
    guard let baseURL = try RecordIndexPersistence.resolvedDirectoryURL(for: configuration.storageLocation) else {
        return nil
    }

    let rootURL = baseURL.appendingPathComponent("benchmark-comparisons", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
}

private func benchmarkUnavailableResult(
    engine: RecordBenchmarkEngine,
    note: String,
    buildMilliseconds: Double? = nil
) -> RecordBenchmarkResult {
    RecordBenchmarkResult(
        engine: engine,
        buildMilliseconds: buildMilliseconds,
        queryMilliseconds: nil,
        matchedRecordCount: nil,
        available: false,
        note: note
    )
}

private func benchmarkLiteralOnlyUnavailableResult(engine: RecordBenchmarkEngine) -> RecordBenchmarkResult {
    benchmarkUnavailableResult(
        engine: engine,
        note: "Literal queries only for this comparison path."
    )
}

private func readBenchmarkMetadata(from fileURL: URL) throws -> BenchmarkCorpusMetadata? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return nil
    }

    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder().decode(BenchmarkCorpusMetadata.self, from: data)
}

private func writeBenchmarkMetadata(_ metadata: BenchmarkCorpusMetadata, to fileURL: URL) throws {
    let data = try JSONEncoder().encode(metadata)
    try data.write(to: fileURL, options: [.atomic])
}

func makeSQLiteFTS5Result(
    units: [BenchmarkSearchUnit],
    query: RecordSearchQuery,
    mode: RecordBenchmarkMode,
    storageRoot: URL?,
    corpusSignature: String
) -> RecordBenchmarkResult {
    guard query.mode == .literal else {
        return benchmarkLiteralOnlyUnavailableResult(engine: .sqliteFTS5)
    }

    do {
        let store = try SQLiteFTS5BenchmarkStore(
            databaseURL: (storageRoot ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("sqlite-fts5.sqlite"),
            metadataURL: (storageRoot ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("sqlite-fts5.meta.json")
        )
        let preparation = try store.prepare(units: units, corpusSignature: corpusSignature, mode: mode)

        let queryClock = ContinuousClock()
        let queryStart = queryClock.now
        let matchedRecordCount = try store.matchCount(for: query)
        let queryMilliseconds = queryStart.duration(to: queryClock.now).milliseconds

        return RecordBenchmarkResult(
            engine: .sqliteFTS5,
            buildMilliseconds: preparation.buildMilliseconds,
            queryMilliseconds: queryMilliseconds,
            matchedRecordCount: matchedRecordCount,
            available: true,
            note: preparation.note
        )
    } catch {
        return benchmarkUnavailableResult(engine: .sqliteFTS5, note: error.localizedDescription)
    }
}

func makeCoreDataResult(
    units: [BenchmarkSearchUnit],
    query: RecordSearchQuery,
    mode: RecordBenchmarkMode,
    storageRoot: URL?,
    corpusSignature: String
) -> RecordBenchmarkResult {
    guard query.mode == .literal else {
        return benchmarkLiteralOnlyUnavailableResult(engine: .coreDataContains)
    }

    #if canImport(CoreData)
    do {
        let directoryURL = (storageRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("core-data", isDirectory: true)
        let store = try CoreDataBenchmarkStore(directoryURL: directoryURL)
        let preparation = try store.prepare(units: units, corpusSignature: corpusSignature, mode: mode)

        let queryClock = ContinuousClock()
        let queryStart = queryClock.now
        let matchedRecordCount = try store.matchCount(for: query)
        let queryMilliseconds = queryStart.duration(to: queryClock.now).milliseconds

        return RecordBenchmarkResult(
            engine: .coreDataContains,
            buildMilliseconds: preparation.buildMilliseconds,
            queryMilliseconds: queryMilliseconds,
            matchedRecordCount: matchedRecordCount,
            available: true,
            note: preparation.note ?? "Core Data substring fetch over a SQLite-backed store."
        )
    } catch {
        return benchmarkUnavailableResult(engine: .coreDataContains, note: error.localizedDescription)
    }
    #else
    return benchmarkUnavailableResult(engine: .coreDataContains, note: "Core Data is unavailable on this platform.")
    #endif
}

func makeCoreSpotlightResult(
    units: [BenchmarkSearchUnit],
    query: RecordSearchQuery,
    mode: RecordBenchmarkMode,
    storageRoot: URL?,
    corpusSignature: String
) async -> RecordBenchmarkResult {
    guard query.mode == .literal else {
        return benchmarkLiteralOnlyUnavailableResult(engine: .coreSpotlight)
    }

    #if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
    do {
        let indexNameSource = storageRoot?.path ?? "ephemeral"
        let indexName = "recallkit-benchmark-\(String(StableHasher.hash(bytes: Array(indexNameSource.utf8)), radix: 16))"
        let store = CoreSpotlightBenchmarkStore(indexName: indexName)
        let preparation = try await store.prepare(units: units, corpusSignature: corpusSignature, mode: mode)

        let queryClock = ContinuousClock()
        let queryStart = queryClock.now
        let matchedRecordCount = try await store.matchCount(for: query)
        let queryMilliseconds = queryStart.duration(to: queryClock.now).milliseconds

        return RecordBenchmarkResult(
            engine: .coreSpotlight,
            buildMilliseconds: preparation.buildMilliseconds,
            queryMilliseconds: queryMilliseconds,
            matchedRecordCount: matchedRecordCount,
            available: true,
            note: preparation.note ?? "Apple system on-device index."
        )
    } catch {
        return benchmarkUnavailableResult(engine: .coreSpotlight, note: error.localizedDescription)
    }
    #else
    return benchmarkUnavailableResult(engine: .coreSpotlight, note: "Core Spotlight is unavailable on this platform.")
    #endif
}

private final class SQLiteFTS5BenchmarkStore {
    private let databaseURL: URL
    private let metadataURL: URL

    init(databaseURL: URL, metadataURL: URL) throws {
        self.databaseURL = databaseURL
        self.metadataURL = metadataURL
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func prepare(units: [BenchmarkSearchUnit], corpusSignature: String, mode: RecordBenchmarkMode) throws -> BenchmarkPreparationResult {
        let clock = ContinuousClock()
        let metadata = try readBenchmarkMetadata(from: metadataURL)

        if mode == .reuseExistingIndex,
           metadata?.schemaVersion == 1,
           metadata?.corpusSignature == corpusSignature,
           FileManager.default.fileExists(atPath: databaseURL.path) {
            return BenchmarkPreparationResult(
                buildMilliseconds: 0,
                note: makeSQLiteNote(from: metadata?.variant, reused: true)
            )
        }

        try removeSQLiteFiles(at: databaseURL)

        let buildStart = clock.now
        let variant = try buildDatabase(units: units)
        let buildMilliseconds = buildStart.duration(to: clock.now).milliseconds

        try writeBenchmarkMetadata(
            BenchmarkCorpusMetadata(schemaVersion: 1, corpusSignature: corpusSignature, variant: variant),
            to: metadataURL
        )

        let note = makeSQLiteNote(from: variant, reused: false, priorMetadata: metadata)
        return BenchmarkPreparationResult(buildMilliseconds: buildMilliseconds, note: note)
    }

    func matchCount(for query: RecordSearchQuery) throws -> Int {
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }

        let statement = try database.prepare(
            sql: "SELECT record_id, collection, field, tags FROM searchable WHERE searchable MATCH ?;"
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(text: makeSQLiteMatchQuery(from: query.text), to: statement, index: 1)

        var recordIDs: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let recordID = database.columnText(statement, index: 0),
                  let collection = database.columnText(statement, index: 1),
                  let field = database.columnText(statement, index: 2) else {
                continue
            }

            let tags = database.columnText(statement, index: 3) ?? ""

            guard query.collections.isEmpty || query.collections.contains(collection) else {
                continue
            }
            guard query.fields.isEmpty || query.fields.contains(field) else {
                continue
            }
            guard query.requiredTags.allSatisfy({ tags.localizedCaseInsensitiveContains("|\($0)|") }) else {
                continue
            }

            recordIDs.insert(recordID)
        }

        return recordIDs.count
    }

    private func buildDatabase(units: [BenchmarkSearchUnit]) throws -> String {
        let database = try SQLiteDatabase(url: databaseURL)
        defer { database.close() }

        let variant: String
        do {
            try createSearchableTable(in: database, tokenizer: "trigram")
            variant = "trigram"
        } catch {
            try database.execute(sql: "DROP TABLE IF EXISTS searchable;")
            try createSearchableTable(in: database, tokenizer: "unicode61 remove_diacritics 2")
            variant = "unicode61"
        }

        try database.execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        let statement = try database.prepare(
            sql: "INSERT INTO searchable(unit_id, record_id, collection, field, tags, content) VALUES (?, ?, ?, ?, ?, ?);"
        )

        defer {
            sqlite3_finalize(statement)
            _ = sqlite3_exec(database.handle, "COMMIT;", nil, nil, nil)
        }

        for unit in units {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try database.bind(text: unit.unitID, to: statement, index: 1)
            try database.bind(text: unit.recordID, to: statement, index: 2)
            try database.bind(text: unit.collection, to: statement, index: 3)
            try database.bind(text: unit.field, to: statement, index: 4)
            try database.bind(text: benchmarkTagString(unit.tags), to: statement, index: 5)
            try database.bind(text: unit.text, to: statement, index: 6)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw database.lastError()
            }
        }

        try database.execute(sql: "COMMIT;")
        return variant
    }

    private func createSearchableTable(in database: SQLiteDatabase, tokenizer: String) throws {
        try database.execute(
            sql: """
            CREATE VIRTUAL TABLE searchable USING fts5(
                unit_id UNINDEXED,
                record_id UNINDEXED,
                collection UNINDEXED,
                field UNINDEXED,
                tags UNINDEXED,
                content,
                tokenize = '\(tokenizer)'
            );
            """
        )
    }

    private func makeSQLiteNote(from variant: String?, reused: Bool, priorMetadata: BenchmarkCorpusMetadata? = nil) -> String {
        let tokenizerNote: String
        switch variant {
        case "trigram":
            tokenizerNote = "Tokenizer: trigram"
        case "unicode61":
            tokenizerNote = "Tokenizer: unicode61 fallback"
        default:
            tokenizerNote = "Tokenizer: default"
        }

        if reused {
            return "Reused persisted index. \(tokenizerNote)."
        }

        if priorMetadata?.corpusSignature != nil {
            return "Rebuilt persisted index. \(tokenizerNote)."
        }

        return tokenizerNote + "."
    }

    private func makeSQLiteMatchQuery(from literal: String) -> String {
        let escaped = literal.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

private final class SQLiteDatabase {
    fileprivate var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, handle != nil else {
            throw BenchmarkComparisonError.invalidSQLiteDatabase("Failed to open SQLite database at \(url.path)")
        }
    }

    func close() {
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    func execute(sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            defer { sqlite3_free(errorPointer) }
            let message = errorPointer.map { String(cString: $0) } ?? "SQLite execution failed"
            throw BenchmarkComparisonError.invalidSQLiteDatabase(message)
        }
    }

    func prepare(sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        return statement
    }

    func bind(text: String, to statement: OpaquePointer?, index: Int32) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, destructor) == SQLITE_OK else {
            throw lastError()
        }
    }

    func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    func lastError() -> BenchmarkComparisonError {
        BenchmarkComparisonError.invalidSQLiteDatabase(
            handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "SQLite error"
        )
    }
}

private func removeSQLiteFiles(at databaseURL: URL) throws {
    let fileManager = FileManager.default
    let companionPaths = [
        databaseURL,
        URL(fileURLWithPath: databaseURL.path + "-wal"),
        URL(fileURLWithPath: databaseURL.path + "-shm")
    ]

    for url in companionPaths where fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
    }
}

#if canImport(CoreData)
private final class CoreDataBenchmarkStore {
    private let directoryURL: URL
    private let storeURL: URL
    private let metadataURL: URL
    private let model: NSManagedObjectModel
    private let persistentContainer: NSPersistentContainer

    init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        self.storeURL = directoryURL.appendingPathComponent("RecallKit.sqlite")
        self.metadataURL = directoryURL.appendingPathComponent("meta.json")
        self.model = Self.makeManagedObjectModel()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.persistentContainer = NSPersistentContainer(name: "RecallKitBenchmark", managedObjectModel: model)

        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        persistentContainer.persistentStoreDescriptions = [description]

        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        persistentContainer.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let loadError {
            throw loadError
        }
    }

    func prepare(units: [BenchmarkSearchUnit], corpusSignature: String, mode: RecordBenchmarkMode) throws -> BenchmarkPreparationResult {
        let existingMetadata = try readBenchmarkMetadata(from: metadataURL)
        if mode == .reuseExistingIndex,
           existingMetadata?.schemaVersion == 1,
           existingMetadata?.corpusSignature == corpusSignature,
           FileManager.default.fileExists(atPath: storeURL.path) {
            return BenchmarkPreparationResult(
                buildMilliseconds: 0,
                note: "Reused persisted Core Data store."
            )
        }

        let coordinator = persistentContainer.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        try removeCoreDataFiles()

        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false

        let semaphore = DispatchSemaphore(value: 0)
        var addError: Error?
        coordinator.addPersistentStore(with: description) { _, error in
            addError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let addError {
            throw addError
        }

        let clock = ContinuousClock()
        let buildStart = clock.now

        let entity = model.entitiesByName["BenchmarkSearchUnit"]!
        let objects = units.map { unit in
            [
                "unitID": unit.unitID,
                "recordID": unit.recordID,
                "collection": unit.collection,
                "field": unit.field,
                "tags": benchmarkTagString(unit.tags),
                "content": unit.text
            ]
        }

        let insertRequest = NSBatchInsertRequest(entity: entity, objects: objects)
        insertRequest.resultType = .statusOnly
        let context = persistentContainer.newBackgroundContext()
        try context.performAndWait {
            _ = try context.execute(insertRequest)
        }

        let buildMilliseconds = buildStart.duration(to: clock.now).milliseconds
        try writeBenchmarkMetadata(
            BenchmarkCorpusMetadata(schemaVersion: 1, corpusSignature: corpusSignature, variant: nil),
            to: metadataURL
        )

        return BenchmarkPreparationResult(
            buildMilliseconds: buildMilliseconds,
            note: "Core Data substring fetch over SQLite."
        )
    }

    func matchCount(for query: RecordSearchQuery) throws -> Int {
        let request = NSFetchRequest<NSDictionary>(entityName: "BenchmarkSearchUnit")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["recordID"]
        request.returnsDistinctResults = true

        let operatorSuffix = benchmarkCaseInsensitive(query) ? "[cd]" : ""
        var predicates: [NSPredicate] = [
            NSPredicate(format: "content CONTAINS\(operatorSuffix) %@", query.text)
        ]

        if !query.collections.isEmpty {
            predicates.append(NSPredicate(format: "collection IN %@", Array(query.collections).sorted()))
        }
        if !query.fields.isEmpty {
            predicates.append(NSPredicate(format: "field IN %@", Array(query.fields).sorted()))
        }
        for tag in query.requiredTags.sorted() {
            predicates.append(NSPredicate(format: "tags CONTAINS[c] %@", "|\(tag)|"))
        }

        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        let context = persistentContainer.newBackgroundContext()
        return try context.performAndWait {
            try context.fetch(request).count
        }
    }

    private func removeCoreDataFiles() throws {
        let fileManager = FileManager.default
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
            metadataURL
        ]

        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private static func makeManagedObjectModel() -> NSManagedObjectModel {
        let unitEntity = NSEntityDescription()
        unitEntity.name = "BenchmarkSearchUnit"
        unitEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        func attribute(name: String) -> NSAttributeDescription {
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = .stringAttributeType
            attribute.isOptional = false
            return attribute
        }

        unitEntity.properties = [
            attribute(name: "unitID"),
            attribute(name: "recordID"),
            attribute(name: "collection"),
            attribute(name: "field"),
            attribute(name: "tags"),
            attribute(name: "content")
        ]

        let model = NSManagedObjectModel()
        model.entities = [unitEntity]
        return model
    }
}
#endif

#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
private struct CoreSpotlightClientState: Codable {
    let schemaVersion: Int
    let corpusSignature: String
}

private final class CoreSpotlightBenchmarkStore {
    private let index: CSSearchableIndex

    init(indexName: String) {
        index = CSSearchableIndex(name: indexName, protectionClass: .completeUntilFirstUserAuthentication)
    }

    func prepare(units: [BenchmarkSearchUnit], corpusSignature: String, mode: RecordBenchmarkMode) async throws -> BenchmarkPreparationResult {
        guard CSSearchableIndex.isIndexingAvailable() else {
            throw BenchmarkComparisonError.coreSpotlightUnavailable
        }

        let expectedState = try JSONEncoder().encode(CoreSpotlightClientState(schemaVersion: 1, corpusSignature: corpusSignature))
        let existingState = try await fetchLastClientState()

        if mode == .reuseExistingIndex, existingState == expectedState {
            return BenchmarkPreparationResult(
                buildMilliseconds: 0,
                note: "Reused persisted Core Spotlight index."
            )
        }

        let clock = ContinuousClock()
        let buildStart = clock.now

        try await deleteAllSearchableItems()
        index.beginBatch()

        for batch in units.chunked(into: 250) {
            try await indexItems(batch.map(makeItem(from:)))
        }

        try await endBatch(with: expectedState)
        let buildMilliseconds = buildStart.duration(to: clock.now).milliseconds

        return BenchmarkPreparationResult(
            buildMilliseconds: buildMilliseconds,
            note: "Apple system on-device index."
        )
    }

    func matchCount(for query: RecordSearchQuery) async throws -> Int {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["containerIdentifier", "keywords"]

        let searchQuery = CSSearchQuery(
            queryString: makeQueryString(for: query),
            queryContext: context
        )

        var recordIDs: Set<String> = []
        for try await result in searchQuery.results {
            let item = result.item
            let attributeSet = item.attributeSet
            let collection = item.domainIdentifier ?? ""
            let field = attributeSet.containerIdentifier ?? ""
            let tags = Set((attributeSet.keywords ?? []).map { $0.lowercased() })

            guard query.collections.isEmpty || query.collections.contains(collection) else {
                continue
            }
            guard query.fields.isEmpty || query.fields.contains(field) else {
                continue
            }
            guard query.requiredTags.allSatisfy({ tags.contains($0.lowercased()) }) else {
                continue
            }

            let parts = item.uniqueIdentifier.split(separator: "\u{001F}")
            if parts.count >= 2 {
                recordIDs.insert(String(parts[1]))
            }
        }

        return recordIDs.count
    }

    private func fetchLastClientState() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            index.fetchLastClientState { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func deleteAllSearchableItems() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteAllSearchableItems { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func indexItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func endBatch(with clientState: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.endBatch(withClientState: clientState) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func makeItem(from unit: BenchmarkSearchUnit) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .plainText)
        attributeSet.contentDescription = unit.text
        attributeSet.containerIdentifier = unit.field
        attributeSet.keywords = unit.tags
        attributeSet.displayName = unit.field
        attributeSet.title = unit.field == "title" ? unit.text : unit.recordID

        return CSSearchableItem(
            uniqueIdentifier: unit.unitID,
            domainIdentifier: unit.collection,
            attributeSet: attributeSet
        )
    }

    private func makeQueryString(for query: RecordSearchQuery) -> String {
        let modifiers = benchmarkCaseInsensitive(query) ? "c" : ""
        let escaped = escapeCoreSpotlightLiteral(query.text)
        return "contentDescription == '*\(escaped)*'\(modifiers)"
    }

    private func escapeCoreSpotlightLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else {
            return isEmpty ? [] : [self]
        }

        var output: [[Element]] = []
        output.reserveCapacity((count / size) + 1)

        var startIndex = 0
        while startIndex < count {
            let endIndex = Swift.min(startIndex + size, count)
            output.append(Array(self[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return output
    }
}
#endif