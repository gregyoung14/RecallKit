import Foundation

enum SearchStorage: Sendable {
    case memory([UInt64: [UInt32]])
    case binary(BinaryPostingsStore)
}

struct OverlaySearchStorage: Sendable {
    let documents: [IndexedDocument]
    let storage: SearchStorage
    let tombstones: Set<UInt32>
}

struct PersistedIndexLocation: Sendable, Hashable {
    let indexDirectoryURL: URL
    let generationID: String
}

struct BinaryPostingsStore: Sendable {
    let lookupTable: BinaryLookupTable
    let postingsData: Data

    func postings(for hash: UInt64) -> [UInt32] {
        guard let entry = lookupTable.entry(for: hash) else {
            return []
        }

        return PostingCodec.decode(postingsData, offset: Int(entry.offset), length: Int(entry.length))
    }
}

public struct SearchIndex: Sendable {
    public let rootURL: URL
    public let configuration: IndexConfiguration
    public let documents: [IndexedDocument]
    public let metadata: IndexMetadata

    private let storage: SearchStorage
    private let baseDocuments: [IndexedDocument]
    private let overlayStorage: OverlaySearchStorage?
    private let documentLookup: [UInt32: IndexedDocument]
    private let persistedLocation: PersistedIndexLocation?

    init(
        rootURL: URL,
        configuration: IndexConfiguration,
        documents: [IndexedDocument],
        postingLookup: [UInt64: [UInt32]],
        metadata: IndexMetadata,
        persistedLocation: PersistedIndexLocation? = nil
    ) {
        self.rootURL = rootURL
        self.configuration = configuration
        self.documents = documents
        self.metadata = metadata
        storage = .memory(postingLookup)
        baseDocuments = documents
        overlayStorage = nil
        documentLookup = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        self.persistedLocation = persistedLocation
    }

    init(
        rootURL: URL,
        configuration: IndexConfiguration,
        documents: [IndexedDocument],
        binaryStore: BinaryPostingsStore,
        metadata: IndexMetadata,
        persistedLocation: PersistedIndexLocation,
        overlayStorage: OverlaySearchStorage? = nil
    ) {
        self.rootURL = rootURL
        self.configuration = configuration
        self.metadata = metadata
        storage = .binary(binaryStore)
        baseDocuments = documents
        self.overlayStorage = overlayStorage
        self.documents = Self.makeActiveDocuments(baseDocuments: documents, overlayStorage: overlayStorage)
        documentLookup = Dictionary(uniqueKeysWithValues: self.documents.map { ($0.id, $0) })
        self.persistedLocation = persistedLocation
    }

    public var documentCount: Int {
        documents.count
    }

    public func document(for id: UInt32) -> IndexedDocument? {
        documentLookup[id]
    }

    func postings(for hash: UInt64) -> [UInt32] {
        let basePostings = Self.postings(in: storage, for: hash)

        guard let overlayStorage else {
            return basePostings
        }

        let filteredBase = basePostings.filter { !overlayStorage.tombstones.contains($0) }
        let overlayPostings = Self.postings(in: overlayStorage.storage, for: hash)
        return Self.sortedUnion(filteredBase, overlayPostings)
    }

    private static func postings(in storage: SearchStorage, for hash: UInt64) -> [UInt32] {
        switch storage {
        case let .memory(postingLookup):
            return postingLookup[hash] ?? []
        case let .binary(binaryStore):
            return binaryStore.postings(for: hash)
        }
    }

    func memoryBuckets() -> [PostingBucket]? {
        guard case let .memory(postingLookup) = storage else {
            return nil
        }

        return postingLookup.keys.sorted().map { hash in
            PostingBucket(hash: hash, documents: postingLookup[hash] ?? [])
        }
    }

    func currentStatus() -> IndexStatus? {
        guard let persistedLocation else {
            return nil
        }

        return IndexStatus(
            rootURL: rootURL,
            indexDirectoryURL: persistedLocation.indexDirectoryURL,
            generationID: persistedLocation.generationID,
            metadata: metadata
        )
    }

    func currentLocation() -> PersistedIndexLocation? {
        persistedLocation
    }

    private static func makeActiveDocuments(
        baseDocuments: [IndexedDocument],
        overlayStorage: OverlaySearchStorage?
    ) -> [IndexedDocument] {
        guard let overlayStorage else {
            return baseDocuments
        }

        let activeBase = baseDocuments.filter { !overlayStorage.tombstones.contains($0.id) }
        return (activeBase + overlayStorage.documents).sorted { $0.id < $1.id }
    }

    private static func sortedUnion(_ lhs: [UInt32], _ rhs: [UInt32]) -> [UInt32] {
        var leftIndex = 0
        var rightIndex = 0
        var merged: [UInt32] = []
        merged.reserveCapacity(lhs.count + rhs.count)

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
}