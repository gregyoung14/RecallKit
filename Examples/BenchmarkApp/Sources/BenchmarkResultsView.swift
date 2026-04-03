import RecallKit
import SwiftUI

struct BenchmarkResultsView: View {
    let snapshot: RecordBenchmarkSnapshot
    let modeLabel: String

    private let comparisonOrder: [RecordBenchmarkEngine] = [
        .recallKit,
        .sqliteFTS5,
        .coreDataContains,
        .coreSpotlight,
        .naiveScan
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summarySection
                comparisonSection
                noteSection
            }
            .padding(20)
        }
        .navigationTitle("Results")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest Benchmark")
                .font(.title2.weight(.semibold))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                summaryCard(title: "Mode", value: modeLabel)
                summaryCard(title: "Records", value: "\(snapshot.recordCount)")
                summaryCard(title: "RecallKit Build", value: formatMilliseconds(snapshot.buildMilliseconds))
                summaryCard(
                    title: "RecallKit Speedup",
                    value: snapshot.speedup.map { String(format: "%.2fx vs naive", $0) } ?? "Unavailable"
                )
            }
        }
    }

    private var comparisonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine Comparison")
                .font(.title3.weight(.semibold))

            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        headerCell("Engine", width: 180, alignment: .leading)
                        headerCell("Build", width: 110, alignment: .trailing)
                        headerCell("Query", width: 110, alignment: .trailing)
                        headerCell("Matches", width: 90, alignment: .trailing)
                        headerCell("Notes", width: 280, alignment: .leading)
                    }

                    ForEach(comparisonResults, id: \.engine) { result in
                        GridRow {
                            valueCell(result.engine.displayName, width: 180, alignment: .leading, emphasized: result.engine == .recallKit)
                            valueCell(formatMilliseconds(result.buildMilliseconds), width: 110, alignment: .trailing)
                            valueCell(formatMilliseconds(result.queryMilliseconds), width: 110, alignment: .trailing)
                            valueCell(formatMatches(result.matchedRecordCount), width: 90, alignment: .trailing)
                            valueCell(result.note ?? (result.available ? "Ready" : "Unavailable"), width: 280, alignment: .leading)
                        }
                        Divider()
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
            }
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interpretation")
                .font(.headline)
            Text("RecallKit build time is shown separately from query time so you can compare cold rebuilds against warm query latency.")
            Text("Core Spotlight is the Apple system-native on-device index. Core Data is represented as a substring-fetch baseline because Core Data itself does not ship a separate full-text engine.")
            Text("Literal queries are the fair comparison mode across all engines. Regex queries still benchmark RecallKit and naive scan, but the other baselines will report that limitation instead of pretending to support it.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var comparisonResults: [RecordBenchmarkResult] {
        comparisonOrder.compactMap(snapshot.result(for:))
    }

    private func summaryCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func headerCell(_ value: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func valueCell(_ value: String, width: CGFloat, alignment: Alignment, emphasized: Bool = false) -> some View {
        Text(value)
            .font(emphasized ? .body.weight(.semibold) : .body)
            .frame(width: width, alignment: alignment)
            .foregroundStyle(emphasized ? .primary : .secondary)
    }

    private func formatMilliseconds(_ value: Double?) -> String {
        guard let value else {
            return "-"
        }

        return String(format: "%.2f ms", value)
    }

    private func formatMatches(_ value: Int?) -> String {
        guard let value else {
            return "-"
        }

        return "\(value)"
    }
}