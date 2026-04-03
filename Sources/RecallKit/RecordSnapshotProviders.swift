import Foundation
import SQLite3

/// Supplies the full record set used when RecallKit rebuilds its persisted index from source-of-truth storage.
public protocol RecordSnapshotProvider: Sendable {
    func loadRecords() async throws -> [IndexedRecord]
}

/// Snapshot provider backed by an async closure supplied by the host app.
public struct ClosureRecordSnapshotProvider: RecordSnapshotProvider {
    private let loader: @Sendable () async throws -> [IndexedRecord]

    public init(loader: @escaping @Sendable () async throws -> [IndexedRecord]) {
        self.loader = loader
    }

    public func loadRecords() async throws -> [IndexedRecord] {
        try await loader()
    }
}

public enum SQLiteValue: Sendable, Hashable {
    case integer(Int64)
    case float(Double)
    case text(String)
    case blob(Data)
    case null

    public var stringValue: String? {
        switch self {
        case let .text(value):
            return value
        case let .integer(value):
            return String(value)
        case let .float(value):
            return String(value)
        case let .blob(value):
            return String(data: value, encoding: .utf8)
        case .null:
            return nil
        }
    }
}

public struct SQLiteRow: Sendable, Hashable {
    public let values: [String: SQLiteValue]

    public subscript(column: String) -> SQLiteValue? {
        values[column]
    }
}

/// Snapshot provider that reads records from a SQLite database using a read-only query and row mapper.
public struct SQLiteRecordSnapshotProvider: RecordSnapshotProvider {
    private let databaseURL: URL
    private let query: String
    private let mapper: @Sendable (SQLiteRow) throws -> IndexedRecord

    public init(
        databaseURL: URL,
        query: String,
        mapper: @escaping @Sendable (SQLiteRow) throws -> IndexedRecord
    ) {
        self.databaseURL = databaseURL
        self.query = query
        self.mapper = mapper
    }

    public func loadRecords() async throws -> [IndexedRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SQLiteSnapshotError.openFailed(databaseURL.path)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteSnapshotError.prepareFailed(query)
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        let columnNames = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var records: [IndexedRecord] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: SQLiteValue] = [:]
            for index in 0..<columnCount {
                row[columnNames[index]] = sqliteValue(statement: statement, column: index)
            }
            records.append(try mapper(SQLiteRow(values: row)))
        }

        return records
    }

    private func sqliteValue(statement: OpaquePointer?, column: Int) -> SQLiteValue {
        switch sqlite3_column_type(statement, Int32(column)) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, Int32(column)))
        case SQLITE_FLOAT:
            return .float(sqlite3_column_double(statement, Int32(column)))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, Int32(column)) else {
                return .null
            }
            return .text(String(cString: pointer))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, Int32(column)))
            guard let pointer = sqlite3_column_blob(statement, Int32(column)), length > 0 else {
                return .blob(Data())
            }
            return .blob(Data(bytes: pointer, count: length))
        default:
            return .null
        }
    }
}

public enum SQLiteSnapshotError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .openFailed(path):
            return "Failed to open SQLite database at \(path)"
        case let .prepareFailed(query):
            return "Failed to prepare SQLite query: \(query)"
        }
    }
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

#if canImport(CoreData)
import CoreData

public struct CoreDataRecordSnapshotProvider: RecordSnapshotProvider {
    private let context: UncheckedBox<NSManagedObjectContext>
    private let fetchRequest: UncheckedBox<NSFetchRequest<NSManagedObject>>
    private let mapper: UncheckedBox<(NSManagedObject) throws -> IndexedRecord>

    public init(
        context: NSManagedObjectContext,
        fetchRequest: NSFetchRequest<NSManagedObject>,
        mapper: @escaping (NSManagedObject) throws -> IndexedRecord
    ) {
        self.context = UncheckedBox(context)
        self.fetchRequest = UncheckedBox(fetchRequest.copy() as! NSFetchRequest<NSManagedObject>)
        self.mapper = UncheckedBox(mapper)
    }

    public func loadRecords() async throws -> [IndexedRecord] {
        try await withCheckedThrowingContinuation { continuation in
            context.value.perform {
                do {
                    let objects = try context.value.fetch(fetchRequest.value)
                    continuation.resume(returning: try objects.map(mapper.value))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif

#if canImport(SwiftData)
import SwiftData

@available(iOS 17.0, macOS 14.0, *)
public struct SwiftDataRecordSnapshotProvider<Model: PersistentModel>: RecordSnapshotProvider {
    private let context: UncheckedBox<ModelContext>
    private let descriptor: UncheckedBox<FetchDescriptor<Model>>
    private let mapper: UncheckedBox<(Model) throws -> IndexedRecord>

    public init(
        context: ModelContext,
        descriptor: FetchDescriptor<Model> = FetchDescriptor<Model>(),
        mapper: @escaping (Model) throws -> IndexedRecord
    ) {
        self.context = UncheckedBox(context)
        self.descriptor = UncheckedBox(descriptor)
        self.mapper = UncheckedBox(mapper)
    }

    public func loadRecords() async throws -> [IndexedRecord] {
        try await MainActor.run {
            try context.value.fetch(descriptor.value).map(mapper.value)
        }
    }
}
#endif