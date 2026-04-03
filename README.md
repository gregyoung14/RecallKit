# RecallKit

[![CI](https://github.com/gregyoung14/RecallKit/actions/workflows/ci.yml/badge.svg)](https://github.com/gregyoung14/RecallKit/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%2B%20%7C%20macOS%2013%2B-blue)](https://developer.apple.com/swift)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)](https://swift.org/package-manager)
[![License](https://img.shields.io/github/license/gregyoung14/RecallKit)](https://github.com/gregyoung14/RecallKit/blob/main/LICENSE)
[![Stars](https://img.shields.io/github/stars/gregyoung14/RecallKit?style=social)](https://github.com/gregyoung14/RecallKit)

RecallKit is an iOS-first Swift package for embedding sparse n-gram indexing into apps that store large amounts of local context. The core use case is app memory, notes, chat history, local knowledge stores, and other on-device records that need fast lookup without shipping a server search stack.

The primary surface is an actor-based record index service with batch upsert/delete, crash-safe rebuilds, overlay compaction, memory budgeting, app-group aware storage, and adapters for common iOS storage layers.

## What the package provides

- XXH3-backed sparse n-gram indexing with upstream-style byte-pair weights.
- `RecallKitIndexService`, an async actor for record indexing, querying, compaction, rebuild, and status inspection.
- Record chunking tuned for app-sized memory payloads with configurable chunk and overlap budgets.
- Persisted snapshot plus overlay storage for fast writes and background compaction.
- Budget controls for resident chunk bytes, mapped index bytes, chunk count, and chunk size.
- Storage adapters for closure-based blobs, SQLite, Core Data, and SwiftData.
- iOS background compaction support via `BGProcessingTask`.
- Data-protection aware storage locations, including app group containers.
- An example iOS benchmark app that exercises the record-based actor service.

## Package layout

```text
.
├── Package.swift
├── Sources/
├── Tests/
├── Examples/
│   └── BenchmarkApp/
└── .github/
    └── workflows/
```

## Install

```swift
dependencies: [
    .package(url: "https://github.com/gregyoung14/RecallKit.git", from: "0.1.0")
]
```

Then depend on the library product:

```swift
.product(name: "RecallKit", package: "RecallKit")
```

## iOS-first quick start

```swift
import RecallKit

let provider = ClosureRecordSnapshotProvider {
    [
        IndexedRecord(
            id: "msg-1",
            collection: "messages",
            title: "SearchEngine memory",
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

## Adapters

### App-owned blobs

Use `ClosureRecordSnapshotProvider` when your app already owns the source-of-truth and can produce records from any local store.

### SQLite

Use `SQLiteRecordSnapshotProvider` with a read-only query and a row mapper:

```swift
let provider = SQLiteRecordSnapshotProvider(
    databaseURL: dbURL,
    query: "SELECT id, body, updated_at FROM messages"
) { row in
    IndexedRecord(
        id: row["id"]?.stringValue ?? UUID().uuidString,
        collection: "messages",
        body: row["body"]?.stringValue ?? "",
        updatedAtEpochSeconds: UInt64(row["updated_at"]?.stringValue ?? "0") ?? 0
    )
}
```

### Core Data

Use `CoreDataRecordSnapshotProvider` with a fetch request and mapping closure.

### SwiftData

Use `SwiftDataRecordSnapshotProvider` on iOS 17+ or macOS 14+ with a `ModelContext`, `FetchDescriptor`, and mapping closure.

## Background compaction

On iOS 17+, `IOSBackgroundCompactionCoordinator` registers and schedules a `BGProcessingTask` that calls `compact()` on demand.

```swift
let coordinator = IOSBackgroundCompactionCoordinator(
    taskIdentifier: "com.example.app.memory.compact"
) {
    RecallKit.makeIndexService(configuration: configuration, snapshotProvider: provider)
}

coordinator.register()
try coordinator.schedule(earliestBeginDate: Date().addingTimeInterval(3600))
```

## Benchmarking

The package exposes two benchmark APIs:

- `RecallKit.benchmark(pattern:at:)` for the legacy directory-corpus benchmark path.
- `RecallKit.benchmark(records:query:configuration:mode:progress:)` for the actor-based record index used by iOS apps.

Use `mode: .rebuildAndQuery` when you want to measure full rebuild cost plus query time, and `mode: .reuseExistingIndex` when you want to measure query latency against an already-persisted index.

The record benchmark snapshot now reports side-by-side results for RecallKit, a naive full scan, SQLite FTS5, Core Data substring fetches, and Core Spotlight when the query mode is a fair literal comparison.

The sample app under `Examples/BenchmarkApp` uses the record-based benchmark path, persists its benchmark index inside the iOS sandbox, and includes a dedicated results screen that compares those engines side by side.

### Real sample-app results

The following numbers are from a real run of the included benchmark app over 1,000 synthetic records in `Rebuild + Query` mode. In that run, every engine returned the same 112 matching records.

| Engine | Build | Query | Matches | Notes |
| --- | ---: | ---: | ---: | --- |
| RecallKit | 27,468.03 ms | 5.71 ms | 112 | Rebuilt persisted RecallKit index |
| SQLite FTS5 | 167.62 ms | 16.84 ms | 112 | FTS5 with trigram tokenizer |
| Core Data Contains | 62.02 ms | 9.19 ms | 112 | SQLite-backed Core Data substring fetch |
| Core Spotlight | 2,647.20 ms | 39.32 ms | 112 | Apple system on-device index |
| Naive Scan | - | 17.98 ms | 112 | Direct `NSRegularExpression` scan over all searchable fields |

In that measured run:

- RecallKit query latency was about 3.15x faster than the naive scan.
- RecallKit query latency was about 2.95x faster than SQLite FTS5.
- RecallKit query latency was about 1.61x faster than the Core Data substring baseline.
- RecallKit query latency was about 6.89x faster than Core Spotlight.

These numbers need to be interpreted correctly:

- RecallKit's cold build path is doing chunking, sparse-substring extraction, hash generation, posting-list construction, and persistence in-process in Swift. It is the most expensive setup step in this benchmark.
- SQLite FTS5 and Core Spotlight are mature native indexing systems with highly optimized build pipelines in C and system frameworks.
- The Core Data baseline is not a true full-text inverted index. Its low build cost mainly reflects storing rows in a SQLite-backed object graph, not building the same kind of search structure that RecallKit or FTS5 builds.
- For real app UX, the `reuseExistingIndex` benchmark mode is usually the more important number than cold rebuild cost, because steady-state query latency is what the user feels after the index already exists.

### Why the numbers look like this

The benchmark is intentionally comparing different points in the design space:

- RecallKit spends more work up front to build an in-process sparse inverted index that is specialized for fast repeated local queries.
- SQLite FTS5 is a general-purpose native full-text engine that is extremely fast to build and query, but it is still carrying the abstractions and storage layout of a generic SQL FTS system.
- Core Spotlight is optimized for system-wide discoverability, privacy classes, and integration with Spotlight, not only for the lowest possible in-process query latency inside one app's hot path.
- A naive scan has no index build cost, but every query is linear in corpus size because it must rescan the text.

## How RecallKit works

At a computer-science level, RecallKit is a sparse substring inverted index with exact verification on the back end.

### 1. Records become chunks

RecallKit does not index an entire record as one giant string. It first normalizes each record into searchable fields such as title, body, and custom fields, and then splits large fields into bounded chunks with overlap.

This matters for both theory and practice:

- It keeps the unit of indexing small enough that posting lists point to local regions instead of entire documents.
- It reduces verification cost, because exact matching runs over candidate chunks rather than full records.
- It improves ranking and excerpt generation, because the match context is already localized.

### 2. It indexes a sparse set of substrings, not every substring

Indexing every substring of a string would be quadratic in the input length: there are `O(n^2)` substrings in a string of length `n`. That is not workable for app-sized local memory stores.

RecallKit avoids that blow-up by extracting only a sparse family of substrings from each chunk. It uses a weight table over adjacent byte pairs and selects spans whose endpoint weights dominate the interior weights inside a bounded window.

The important intuition is:

- common byte-pair boundaries are less informative,
- rarer or sharper boundaries tend to create more selective fingerprints,
- and a bounded sparse family can still preserve strong filtering power without materializing all possible substrings.

In the current implementation, the extraction loop is bounded by `maxNGramLength`, so the work is closer to `O(totalBytes * window)` than to unbounded substring enumeration.

### 3. Those sparse substrings are hashed into an inverted index

Each selected sparse substring is hashed with XXH3 and inserted into an inverted index:

- key: sparse substring hash
- value: sorted posting list of chunk IDs that contain that sparse substring

This is the classic inverted-index move. Instead of asking "which substrings occur in this chunk?" at query time, the system asks "which chunks contain these query features?" and answers that by direct posting-list lookup.

The space cost is therefore proportional to the number of selected sparse fingerprints plus posting entries, rather than to the full substring universe.

### 4. Literal queries become posting-list intersections

For a literal query, RecallKit does not look up the whole string as one monolithic key. It computes a covering family of sparse substrings from the query literal and turns those into a query plan.

Conceptually, this is an AND query over postings:

- choose several selective sparse substrings that cover the literal,
- look up each substring hash in the inverted index,
- intersect the posting lists,
- and only verify the surviving candidate chunks exactly.

Why this is sound:

- if a chunk really contains the full literal, then it must contain all of those selected literal substrings,
- so intersecting those posting lists cannot discard a true match,
- and exact verification at the end removes false positives from hashing collisions or from chunks that satisfy the sparse prefilter but not the full string match.

This is the main reason query time drops so sharply compared with a naive scan: most chunks are eliminated before the expensive exact match step ever runs.

### 5. Regex queries use a planner, not blind scanning by default

Regex search is harder because not every regex contains a long mandatory literal. RecallKit uses a regex query planner that extracts mandatory literal structure when possible.

Examples of the planner behavior:

- concatenation becomes AND when both sides imply required literals,
- alternation becomes OR across branches,
- character classes, wildcards, and unsupported constructs degrade toward scan-all,
- and if the regex has no useful required literal at all, RecallKit falls back to full verification.

This is a standard information-retrieval tradeoff: do as much cheap symbolic narrowing as possible up front, then pay the full regex engine cost only on the reduced candidate set.

### 6. Verification is exact, so the index can stay approximate

The sparse hash index is only a prefilter. Final correctness comes from exact matching over the candidate chunks.

That separation is deliberate:

- the index is optimized for fast rejection,
- the verifier is optimized for correctness,
- and combining them gives good throughput without requiring the index itself to encode the full semantics of regex matching.

This is also why hash collisions are acceptable in practice: they may increase the candidate set slightly, but they do not create incorrect final matches because the verifier is exact.

### 7. Time-complexity view

At a high level:

- cold indexing cost is dominated by chunking, sparse-feature extraction, and posting-list construction,
- literal query cost is dominated by posting lookups plus intersection plus exact verification on the surviving candidates,
- naive scan cost is dominated by exact matching over the full corpus every time,
- and steady-state reuse mode shifts almost all cost from build time to query time.

You can think of the query path roughly as:

- prefilter work: sum of posting-list access and merge/intersection costs
- verification work: exact match cost over only the reduced candidate set

That is why RecallKit can beat naive scan even when its build phase is much more expensive: it is paying an indexing cost once so that future queries do much less total work.

### 8. Why RecallKit can beat native baselines on query time

In the measured sample-app run above, RecallKit beat SQLite FTS5, Core Data substring fetches, Core Spotlight, and naive scan on query latency. That does not mean it will always win on every workload, but it does reflect the design:

- RecallKit runs in-process and uses a search structure specialized for repeated local retrieval over chunked app memory.
- Its prefilter is highly selective for literal-heavy queries, so exact verification runs on a small candidate set.
- Core Spotlight pays system-service and framework overhead in exchange for Apple-native search integration.
- Core Data substring fetches still have to do much more text work at query time because they are not using the same sparse-substring inverted structure.
- SQLite FTS5 is a very strong native baseline, but its generic full-text machinery is solving a broader problem than RecallKit's very specific app-memory lookup path.

The right mental model is not "RecallKit beats everything." The right model is:

- RecallKit is trading cold build cost for fast warm local queries,
- and that trade can be very attractive for apps that repeatedly search the same local memory corpus.

## Example app

Generate the Xcode project with XcodeGen:

```bash
cd Examples/BenchmarkApp
xcodegen generate
open RecallKit.xcodeproj
```

The app creates synthetic records that resemble chat memory and local notes, builds the persisted record index, runs indexed queries, and compares them against a naive scan, SQLite FTS5, Core Data substring fetches, and Core Spotlight. It includes both a rebuild benchmark mode and a query-only mode that reuses the existing persisted indexes when the corpus signature matches.

## Current limitations

- Regex decomposition is still custom and pragmatic; it is not yet a full AST or HIR port.
- The iOS-first service supports data protection and rebuildable indexes, but it does not implement application-layer encryption on top of your source store.
- The primary optimization target is embedded record indexing for app-owned local context, not generic directory-scale corpus management.
- Persisted record indexes are versioned, but migration currently rebuilds instead of performing in-place upgrades.
- The new actor service is tested on macOS in CI and intended for iOS apps, but large-scale device benchmarking is still something you should validate in your own workload.

## Verification

- Unit tests pass with `swift test`.
- The package includes a SwiftUI example app in `Examples/BenchmarkApp`.
- CI runs `swift test` on macOS.