import Foundation

struct PreparedRecordChunk: Sendable, Hashable {
    let recordID: String
    let collection: String
    let field: String
    let ordinal: Int
    let updatedAtEpochSeconds: UInt64
    let text: String
    let tags: [String]
    let metadata: [String: String]
}

struct RecordChunker: Sendable {
    let configuration: ChunkingConfiguration

    func chunks(for record: IndexedRecord) -> [PreparedRecordChunk] {
        var chunks: [PreparedRecordChunk] = []

        for (field, text) in record.searchableFields {
            let segments = split(text)
            for (ordinal, segment) in segments.enumerated() where !segment.isEmpty {
                chunks.append(
                    PreparedRecordChunk(
                        recordID: record.id,
                        collection: record.collection,
                        field: field,
                        ordinal: ordinal,
                        updatedAtEpochSeconds: record.updatedAtEpochSeconds,
                        text: segment,
                        tags: record.tags,
                        metadata: record.metadata
                    )
                )
            }
        }

        return chunks
    }

    private func split(_ text: String) -> [String] {
        guard text.utf8.count > configuration.maxChunkBytes else {
            return [text]
        }

        var segments: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let rawEnd = endIndex(in: text, from: start, maxUTF8Bytes: configuration.maxChunkBytes)
            let segmentEnd = preferredBreak(in: text, start: start, rawEnd: rawEnd) ?? rawEnd
            let segment = text[start..<segmentEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                segments.append(String(segment))
            }

            guard segmentEnd < text.endIndex else {
                break
            }

            let overlapStart = backwardIndex(in: text, from: segmentEnd, maxUTF8Bytes: configuration.overlapBytes)
            start = overlapStart < segmentEnd ? overlapStart : segmentEnd
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
        }

        return segments
    }

    private func preferredBreak(in text: String, start: String.Index, rawEnd: String.Index) -> String.Index? {
        guard rawEnd < text.endIndex else {
            return nil
        }

        var cursor = rawEnd
        while cursor > start {
            let previous = text.index(before: cursor)
            if configuration.preferredBreakCharacters.contains(text[previous]) {
                return cursor
            }
            cursor = previous
        }

        return nil
    }

    private func endIndex(in text: String, from start: String.Index, maxUTF8Bytes: Int) -> String.Index {
        var cursor = start
        var byteCount = 0
        var best = start

        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let segmentBytes = String(text[cursor..<next]).utf8.count
            if byteCount + segmentBytes > maxUTF8Bytes {
                break
            }
            byteCount += segmentBytes
            best = next
            cursor = next
        }

        return best
    }

    private func backwardIndex(in text: String, from end: String.Index, maxUTF8Bytes: Int) -> String.Index {
        guard maxUTF8Bytes > 0 else {
            return end
        }

        var cursor = end
        var byteCount = 0

        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let segmentBytes = String(text[previous..<cursor]).utf8.count
            if byteCount + segmentBytes > maxUTF8Bytes {
                break
            }
            byteCount += segmentBytes
            cursor = previous
        }

        return cursor
    }
}