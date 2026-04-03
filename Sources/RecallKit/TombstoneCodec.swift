import Foundation

enum TombstoneCodec {
    static func write(_ tombstones: [UInt32], to fileURL: URL) throws {
        var data = Data()

        for tombstone in tombstones.sorted() {
            data.appendLittleEndian(tombstone)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    static func read(from fileURL: URL) throws -> [UInt32] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw NSError(domain: "RecallKit", code: 40, userInfo: [NSLocalizedDescriptionKey: "tombstones.bin has an invalid length"])
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<UInt32>.size).map {
            data.readLittleEndian(at: $0, as: UInt32.self)
        }
    }
}