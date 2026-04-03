import Foundation

struct SparseCandidate: Hashable {
    let start: Int
    let endExclusive: Int
    let hash: UInt64
}

struct SparseNGramExtractor: Sendable {
    let weightTable: WeightTable
    let maxNGramLength: Int

    init(weightTable: WeightTable = .default, maxNGramLength: Int = 128) {
        self.weightTable = weightTable
        self.maxNGramLength = max(2, maxNGramLength)
    }

    func extractHashes(from data: Data) -> Set<UInt64> {
        extractHashes(from: Array(data))
    }

    func extractHashes(from string: String) -> Set<UInt64> {
        extractHashes(from: Array(string.utf8))
    }

    func extractHashes(from bytes: [UInt8]) -> Set<UInt64> {
        let weights = pairWeights(for: bytes)
        guard !weights.isEmpty else {
            return []
        }

        var hashes: Set<UInt64> = []
        hashes.reserveCapacity(min(weights.count * 2, maxNGramLength * 4))

        for left in weights.indices {
            var maxInside: UInt32 = 0
            let limit = min(weights.count, left + maxNGramLength - 1)

            for right in left..<limit {
                if right >= left + 2 {
                    maxInside = max(maxInside, weights[right - 1])
                }

                if right <= left + 1 || (weights[left] > maxInside && weights[right] > maxInside) {
                    hashes.insert(StableHasher.hash(bytes: bytes[left..<(right + 2)]))
                }
            }
        }

        return hashes
    }

    func coveringHashes(for literal: String, limit: Int) -> [UInt64] {
        let bytes = Array(literal.utf8)
        let weights = pairWeights(for: bytes)
        guard !weights.isEmpty else { return [] }

        var selected: [SparseCandidate] = []
        var frontier = 0
        var nextUncovered = 0

        while nextUncovered < weights.count {
            var bestCandidate: SparseCandidate?

            while frontier <= nextUncovered && frontier < weights.count {
                let endExclusive = widestEndExclusive(in: weights, startingAt: frontier)
                let candidate = SparseCandidate(
                    start: frontier,
                    endExclusive: endExclusive,
                    hash: StableHasher.hash(bytes: bytes[frontier..<endExclusive])
                )

                if bestCandidate == nil
                    || candidate.endExclusive > bestCandidate!.endExclusive
                    || (candidate.endExclusive == bestCandidate!.endExclusive && candidate.start < bestCandidate!.start) {
                    bestCandidate = candidate
                }
                frontier += 1
            }

            guard let bestCandidate else {
                break
            }

            selected.append(bestCandidate)
            nextUncovered = bestCandidate.endExclusive - 1
        }

        let deduplicated = deduplicateHashesPreservingOrder(selected.map(\ .hash))
        return Array(deduplicated.prefix(max(1, limit)))
    }

    func debugExtractStrings(from string: String) -> [String] {
        let bytes = Array(string.utf8)
        return allCandidates(in: bytes).map { String(decoding: bytes[$0.start..<$0.endExclusive], as: UTF8.self) }
    }

    private func allCandidates(in bytes: [UInt8]) -> [SparseCandidate] {
        let weights = pairWeights(for: bytes)
        guard !weights.isEmpty else { return [] }

        return buildAllSpans(in: weights).map { start, endExclusive in
            SparseCandidate(
                start: start,
                endExclusive: endExclusive,
                hash: StableHasher.hash(bytes: bytes[start..<endExclusive])
            )
        }
    }

    private func pairWeights(for bytes: [UInt8]) -> [UInt32] {
        guard bytes.count >= 2 else {
            return []
        }

        return bytes.indices.dropLast().map { index in
            weightTable.weight(bytes[index], bytes[index + 1])
        }
    }

    private func buildAllSpans(in weights: [UInt32]) -> [(Int, Int)] {
        var spans: [(Int, Int)] = []

        for left in weights.indices {
            var maxInside: UInt32 = 0
            let limit = min(weights.count, left + maxNGramLength - 1)

            for right in left..<limit {
                if right >= left + 2 {
                    maxInside = max(maxInside, weights[right - 1])
                }

                if right <= left + 1 || (weights[left] > maxInside && weights[right] > maxInside) {
                    spans.append((left, right + 2))
                }
            }
        }

        return spans
    }

    private func widestEndExclusive(in weights: [UInt32], startingAt left: Int) -> Int {
        var maxInside: UInt32 = 0
        var bestRight = left
        let limit = min(weights.count, left + maxNGramLength - 1)

        for right in left..<limit {
            if right >= left + 2 {
                maxInside = max(maxInside, weights[right - 1])
            }

            if right <= left + 1 || (weights[left] > maxInside && weights[right] > maxInside) {
                bestRight = right
            }
        }

        return bestRight + 2
    }

    private func deduplicateHashesPreservingOrder(_ hashes: [UInt64]) -> [UInt64] {
        var seen: Set<UInt64> = []
        return hashes.filter { seen.insert($0).inserted }
    }
}