import Foundation

enum FileTableCodec {
    private static let magic = Array("FRGF".utf8)
    private static let version: UInt32 = 1

    static func write(_ documents: [IndexedDocument], to fileURL: URL) throws {
        var data = Data()
        data.append(contentsOf: magic)
        data.appendLittleEndian(version)
        data.appendLittleEndian(UInt32(documents.count))

        for document in documents {
            let pathBytes = Array(document.relativePath.utf8)
            data.appendLittleEndian(UInt32(pathBytes.count))
            data.appendLittleEndian(UInt64(document.byteCount))
            data.appendLittleEndian(document.modifiedAtEpochSeconds)
            data.append(contentsOf: pathBytes)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    static func read(from fileURL: URL) throws -> [IndexedDocument] {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard Array(data.prefix(4)) == magic else {
            throw NSError(domain: "RecallKit", code: 30, userInfo: [NSLocalizedDescriptionKey: "files.bin has an invalid header"])
        }

        let version = data.readLittleEndian(at: 4, as: UInt32.self)
        guard version == Self.version else {
            throw NSError(domain: "RecallKit", code: 31, userInfo: [NSLocalizedDescriptionKey: "Unsupported files.bin version \(version)"])
        }

        let count = Int(data.readLittleEndian(at: 8, as: UInt32.self))
        var cursor = 12
        var documents: [IndexedDocument] = []
        documents.reserveCapacity(count)

        for documentID in 0..<count {
            let pathLength = Int(data.readLittleEndian(at: cursor, as: UInt32.self))
            cursor += 4

            let byteCount = Int(data.readLittleEndian(at: cursor, as: UInt64.self))
            cursor += 8

            let modifiedAtEpochSeconds = data.readLittleEndian(at: cursor, as: UInt64.self)
            cursor += 8

            let pathData = data[cursor..<(cursor + pathLength)]
            cursor += pathLength

            documents.append(
                IndexedDocument(
                    id: UInt32(documentID),
                    relativePath: String(decoding: pathData, as: UTF8.self),
                    byteCount: byteCount,
                    modifiedAtEpochSeconds: modifiedAtEpochSeconds
                )
            )
        }

        return documents
    }
}