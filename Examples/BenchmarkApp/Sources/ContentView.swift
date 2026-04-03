import Foundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = BenchmarkViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Dataset") {
                    Stepper("Records: \(model.recordCount)", value: $model.recordCount, in: 200...2_000, step: 100)
                    Stepper("Segments per record: \(model.segmentsPerRecord)", value: $model.segmentsPerRecord, in: 12...96, step: 4)
                    Button("Prepare Records", action: model.generateCorpus)

                    if !model.storagePath.isEmpty {
                        Text(model.storagePath)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("Query") {
                    Picker("Benchmark mode", selection: $model.benchmarkMode) {
                        ForEach(BenchmarkRunMode.allCases) { mode in
                            Text(model.benchmarkModeLabel(for: mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Literal or regex pattern", text: $model.pattern)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(model.benchmarkMode == .rebuildAndQuery ? "Run Rebuild Benchmark" : "Run Query-Only Benchmark", action: model.runBenchmark)
                        .disabled(model.pattern.isEmpty)
                }

                Section("Status") {
                    Text(model.status)
                }

                Section("Log") {
                    if model.logLines.isEmpty {
                        Text("Run a benchmark to see phase-by-phase progress.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if let snapshot = model.snapshot {
                    Section("Latest Run") {
                        LabeledContent("Mode") {
                            Text(model.snapshotModeLabel(for: snapshot))
                        }
                        LabeledContent("Records") {
                            Text("\(snapshot.recordCount)")
                        }
                        LabeledContent("RecallKit build") {
                            Text(format(snapshot.buildMilliseconds))
                        }
                        LabeledContent("RecallKit query") {
                            Text(format(snapshot.indexedSearchMilliseconds))
                        }
                        LabeledContent("Naive search") {
                            Text(format(snapshot.naiveSearchMilliseconds))
                        }
                        if let sqliteFTS5 = snapshot.sqliteFTS5SearchMilliseconds {
                            LabeledContent("SQLite FTS5") {
                                Text(format(sqliteFTS5))
                            }
                        }
                        LabeledContent("Candidate chunks") {
                            Text("\(snapshot.candidateChunkCount)")
                        }
                        LabeledContent("RecallKit matched records") {
                            Text("\(snapshot.indexedMatchedRecordCount)")
                        }
                        LabeledContent("Naive matched records") {
                            Text("\(snapshot.naiveMatchedRecordCount)")
                        }

                        if let speedup = snapshot.speedup {
                            LabeledContent("Query speedup (naive/indexed)") {
                                Text(String(format: "%.2fx", speedup))
                            }
                        }

                        Button("Open comparison results") {
                            model.showResults = true
                        }
                    }
                }

                Section("Notes") {
                    Text("The app generates in-memory records that resemble chat memory and note storage, persists the actor-backed sparse n-gram index inside the iOS sandbox, and compares RecallKit against a naive scan, SQLite FTS5, Core Data substring fetches, and Core Spotlight.")
                    Text("Literal queries use the sparse prefilter directly. Regex queries still work, but complex forms can widen the candidate set.")
                    Text("Rebuild mode recreates the full index before searching. Query-only mode reuses the persisted RecallKit index and any persisted comparison stores whose corpus signature still matches.")
                    Text("Core Spotlight is the Apple system search baseline. Core Data is shown as a substring-fetch baseline because Core Data itself does not expose a separate full-text engine.")
                    Text("The displayed speedup compares RecallKit query time against naive query time only. The results screen shows all comparison engines side by side.")
                }
            }
            .navigationTitle("RecallKit Bench")
            .navigationDestination(isPresented: $model.showResults) {
                if let snapshot = model.snapshot {
                    BenchmarkResultsView(
                        snapshot: snapshot,
                        modeLabel: model.snapshotModeLabel(for: snapshot)
                    )
                }
            }
        }
    }

    private func format(_ milliseconds: Double) -> String {
        String(format: "%.2f ms", milliseconds)
    }
}