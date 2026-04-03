import Combine
import Foundation
import RecallKit

enum BenchmarkCorpusFactory {
    static func createSampleRecords(recordCount: Int, segmentsPerRecord: Int) -> [IndexedRecord] {
        (0..<recordCount).map { recordIndex in
            IndexedRecord(
                id: "record-\(recordIndex)",
                collection: recordIndex.isMultiple(of: 4) ? "messages" : "notes",
                title: recordIndex.isMultiple(of: 9) ? "SearchEngine memory \(recordIndex)" : "Generated memory \(recordIndex)",
                body: makeRecordBody(recordIndex: recordIndex, segmentsPerRecord: segmentsPerRecord),
                fields: [
                    "summary": recordIndex.isMultiple(of: 7)
                        ? "This summary references sparse indexing and app memory retrieval."
                        : "This summary tracks generated context item \(recordIndex)."
                ],
                tags: recordIndex.isMultiple(of: 3) ? ["memory", "ios"] : ["context"],
                metadata: ["module": "Module\(recordIndex % 12)"]
            )
        }
    }

    private static func makeRecordBody(recordIndex: Int, segmentsPerRecord: Int) -> String {
        var segments: [String] = []

        for segmentIndex in 0..<segmentsPerRecord {
            if recordIndex.isMultiple(of: 27) && segmentIndex == segmentsPerRecord / 2 {
                segments.append("SearchEngine powers sparse-index retrieval inside the app memory layer.")
                segments.append("The actor-backed index compacts overlays in the background for fast lookup.")
            } else {
                segments.append("Generated context \(recordIndex)-\(segmentIndex) keeps local state available for retrieval.")
            }
        }

        return segments.joined(separator: "\n")
    }
}

enum BenchmarkRunMode: String, CaseIterable, Identifiable {
    case rebuildAndQuery
    case reuseExistingIndex

    var id: String { rawValue }
}

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published var recordCount = 600
    @Published var segmentsPerRecord = 32
    @Published var pattern = "SearchEngine"
    @Published var benchmarkMode: BenchmarkRunMode = .rebuildAndQuery
    @Published var showResults = false
    @Published private(set) var status = "Ready"
    @Published private(set) var snapshot: RecordBenchmarkSnapshot?
    @Published private(set) var storagePath = ""
    @Published private(set) var logLines: [String] = []

    private var generatedRecords: [IndexedRecord] = []
    private var generatedConfiguration: (recordCount: Int, segmentsPerRecord: Int)?

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func generateCorpus() {
        status = "Preparing records..."
        snapshot = nil
        showResults = false
        logLines = []
        appendLog("Preparing \(recordCount) synthetic records with \(segmentsPerRecord) segments each.")

        let requestedRecordCount = recordCount
        let requestedSegments = segmentsPerRecord

        Task {
            let records = await Task.detached(priority: .utility) {
                BenchmarkCorpusFactory.createSampleRecords(
                    recordCount: requestedRecordCount,
                    segmentsPerRecord: requestedSegments
                )
            }.value

            generatedRecords = records
            generatedConfiguration = (requestedRecordCount, requestedSegments)
            status = "Prepared \(requestedRecordCount) records"
            appendLog("Prepared \(requestedRecordCount) records.")
        }
    }

    func runBenchmark() {
        status = "Running benchmark..."
        snapshot = nil
        showResults = false
        logLines = []
        appendLog("Starting \(benchmarkModeLabel(for: benchmarkMode)) for \(recordCount) records, \(segmentsPerRecord) segments per record, query '\(pattern)'.")

        let requestedPattern = pattern
        let requestedRecordCount = recordCount
        let requestedSegments = segmentsPerRecord
        let requestedMode = benchmarkMode

        Task {
            do {
                let records = try await resolveRecords(
                    recordCount: requestedRecordCount,
                    segmentsPerRecord: requestedSegments
                )
                appendLog("Resolved \(records.count) records totaling about \(formatMegabytes(sourceBytes(for: records))) of source text.")

                let storageURL = try benchmarkStorageURL(resetIndex: requestedMode == .rebuildAndQuery)
                let query = RecordSearchQuery(
                    text: requestedPattern,
                    mode: queryMode(for: requestedPattern)
                )
                let configuration = RecordIndexServiceConfiguration(
                    storageLocation: .custom(storageURL),
                    dataProtection: .completeUntilFirstUserAuthentication,
                    compactionThreshold: 4_096
                )

                let snapshot = try await RecallKit.benchmark(
                    records: records,
                    query: query,
                    configuration: configuration,
                    mode: requestedMode == .reuseExistingIndex ? .reuseExistingIndex : .rebuildAndQuery
                ) { progress in
                    self.status = progress.message
                    self.appendLog(self.format(progress: progress))
                }

                storagePath = storageURL.path
                self.snapshot = snapshot
                showResults = true
                status = "Benchmark complete"
                appendLog("Complete: mode=\(snapshotModeLabel(for: snapshot)), RecallKit build \(formatMilliseconds(snapshot.buildMilliseconds)), RecallKit query \(formatMilliseconds(snapshot.indexedSearchMilliseconds)), naive scan \(formatMilliseconds(snapshot.naiveSearchMilliseconds)).")
            } catch {
                status = error.localizedDescription
                appendLog("Benchmark failed: \(error.localizedDescription)")
            }
        }
    }

    private func resolveRecords(recordCount: Int, segmentsPerRecord: Int) async throws -> [IndexedRecord] {
        if let generatedConfiguration,
           generatedConfiguration.recordCount == recordCount,
           generatedConfiguration.segmentsPerRecord == segmentsPerRecord,
           !generatedRecords.isEmpty {
            return generatedRecords
        }

        let records = await Task.detached(priority: .utility) {
            BenchmarkCorpusFactory.createSampleRecords(recordCount: recordCount, segmentsPerRecord: segmentsPerRecord)
        }.value

        generatedRecords = records
        generatedConfiguration = (recordCount, segmentsPerRecord)
        return records
    }

    private func benchmarkStorageURL(resetIndex: Bool) throws -> URL {
        let rootURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecallKitRecordBench", isDirectory: true)

        if resetIndex, FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private func queryMode(for pattern: String) -> RecordQueryMode {
        let regexCharacters = CharacterSet(charactersIn: "[](){}.*+?|\\^$")
        return pattern.rangeOfCharacter(from: regexCharacters) == nil ? .literal : .regex
    }

    private func sourceBytes(for records: [IndexedRecord]) -> Int {
        records.reduce(0) { partial, record in
            partial
                + (record.title?.utf8.count ?? 0)
                + record.body.utf8.count
                + record.fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
    }

    private func appendLog(_ message: String) {
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        logLines.append(line)
        if logLines.count > 40 {
            logLines.removeFirst(logLines.count - 40)
        }
        print("RecallKit \(line)")
    }

    private func format(progress: RecordBenchmarkProgress) -> String {
        var components = [progress.message]

        if let elapsedMilliseconds = progress.elapsedMilliseconds {
            components.append("\(formatMilliseconds(elapsedMilliseconds))")
        }
        if let chunkCount = progress.chunkCount {
            components.append("chunks=\(chunkCount)")
        }
        if let ngramCount = progress.ngramCount {
            components.append("ngrams=\(ngramCount)")
        }
        if let candidateChunkCount = progress.candidateChunkCount {
            components.append("candidates=\(candidateChunkCount)")
        }
        if let matchedRecordCount = progress.matchedRecordCount {
            components.append("matches=\(matchedRecordCount)")
        }

        return components.joined(separator: " | ")
    }

    private func formatMilliseconds(_ value: Double) -> String {
        String(format: "%.2f ms", value)
    }

    private func formatMegabytes(_ bytes: Int) -> String {
        String(format: "%.2f MB", Double(bytes) / 1_048_576.0)
    }

    func benchmarkModeLabel(for mode: BenchmarkRunMode) -> String {
        switch mode {
        case .rebuildAndQuery:
            return "Rebuild + Query"
        case .reuseExistingIndex:
            return "Reuse Existing Index"
        }
    }

    func snapshotModeLabel(for snapshot: RecordBenchmarkSnapshot) -> String {
        snapshot.mode == .reuseExistingIndex ? "Reuse Existing Index" : "Rebuild + Query"
    }
}