# ``RecallKit``

Build fast, on-device search into app memory, notes, chat history, and other local record stores.

## Overview

RecallKit is centered on the actor-based ``RecallKitIndexService``. You feed it ``IndexedRecord`` values from your app, persist an index in app-controlled storage, and query that index with ``RecordSearchQuery``. Matches are prefiltered by the sparse index and then verified exactly before being returned as ``RecordSearchHit`` values.

The package is optimized for embedded, local-first search flows rather than server-backed search infrastructure. The main integration path is:

1. Define a ``RecordSnapshotProvider`` for your source-of-truth.
2. Create a ``RecallKitIndexService`` with ``RecallKit/makeIndexService(configuration:snapshotProvider:)``.
3. Call ``RecallKitIndexService/bootstrap()`` once at launch.
4. Keep the index fresh with ``RecallKitIndexService/upsert(_:)`` or ``RecallKitIndexService/rebuild()``.
5. Query with ``RecallKitIndexService/search(_:)``.

## Quick Start

```swift
import RecallKit

let provider = ClosureRecordSnapshotProvider {
    [
        IndexedRecord(
            id: "msg-1",
            collection: "messages",
            title: "Searchable memory",
            body: "Sparse indexing keeps local app memory searchable.",
            tags: ["memory", "ios"],
            metadata: ["conversation": "alpha"]
        )
    ]
}

let configuration = RecordIndexServiceConfiguration(
    storageLocation: .applicationSupport(subdirectory: "AppMemoryIndex"),
    dataProtection: .completeUntilFirstUserAuthentication,
    recoveryStrategy: .rebuildFromSource,
    compactionThreshold: 4_096
)

let service = RecallKit.makeIndexService(
    configuration: configuration,
    snapshotProvider: provider
)

try await service.bootstrap()

try await service.upsert([
    IndexedRecord(
        id: "msg-2",
        collection: "messages",
        body: "The actor-backed index supports batch writes and fast lookup.",
        tags: ["memory"]
    )
])

let report = try await service.search(
    RecordSearchQuery(
        text: "fast lookup",
        mode: .literal,
        collections: ["messages"]
    )
)

for hit in report.hits {
    print(hit.recordID, hit.collection, hit.excerpt)
}
```

## Storage Providers

Use ``ClosureRecordSnapshotProvider`` when your app already owns the source-of-truth in memory, files, or a custom database layer. When your records already live in a common Apple persistence stack, RecallKit also ships snapshot providers for SQLite, Core Data, and SwiftData.

DocC generated on macOS will cover the cross-platform and macOS-visible API surface. iOS-only integration types such as background compaction remain available in the package even when they are not part of the default hosted documentation build.

## Benchmarking

RecallKit exposes benchmark helpers for both the modern record-based API and the legacy file-based search path. For app integrations, the record benchmark is the one that matters most because it measures the same actor service, persistence model, and query flow used in production.

## Topics

### Essentials

- ``RecallKit``
- ``RecallKitIndexService``
- ``RecordIndexServiceConfiguration``
- ``IndexedRecord``
- ``RecordSearchQuery``
- ``RecordSearchReport``

### Snapshot Providers

- ``RecordSnapshotProvider``
- ``ClosureRecordSnapshotProvider``
- ``SQLiteRecordSnapshotProvider``
- ``CoreDataRecordSnapshotProvider``
- ``SwiftDataRecordSnapshotProvider``

### Legacy File Indexing

- ``SearchIndex``
- ``IndexConfiguration``
- ``SearchConfiguration``
