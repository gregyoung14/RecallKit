import Foundation

struct LookupTableEntry: Sendable, Hashable {
    let hash: UInt64
    let offset: UInt64
    let length: UInt32
}

struct BinaryLookupTable: Sendable {
    private static let magic = Array("FRGL".utf8)
    private static let version: UInt32 = 1
    private static let headerSize = 16
    private static let slotSize = 20

    private let data: Data
    private let capacity: Int

    init(data: Data) throws {
        guard data.count >= Self.headerSize else {
            throw NSError(domain: "RecallKit", code: 20, userInfo: [NSLocalizedDescriptionKey: "lookup.bin is truncated"])
        }

        let magic = Array(data.prefix(4))
        guard magic == Self.magic else {
            throw NSError(domain: "RecallKit", code: 21, userInfo: [NSLocalizedDescriptionKey: "lookup.bin has an invalid header"])
        }

        let version = data.readLittleEndian(at: 4, as: UInt32.self)
        guard version == Self.version else {
            throw NSError(domain: "RecallKit", code: 22, userInfo: [NSLocalizedDescriptionKey: "Unsupported lookup.bin version \(version)"])
        }

        self.data = data
        capacity = Int(data.readLittleEndian(at: 8, as: UInt32.self))
    }

    func entry(for hash: UInt64) -> LookupTableEntry? {
        guard capacity > 0 else {
            return nil
        }

        var slot = Int(truncatingIfNeeded: hash) & (capacity - 1)

        for _ in 0..<capacity {
            let entry = readEntry(at: slot)

            if entry.length == 0 {
                return nil
            }

            if entry.hash == hash {
                return entry
            }

            slot = (slot + 1) & (capacity - 1)
        }

        return nil
    }

    func entries() -> [LookupTableEntry] {
        guard capacity > 0 else {
            return []
        }

        return (0..<capacity).compactMap { slot in
            let entry = readEntry(at: slot)
            return entry.length == 0 ? nil : entry
        }
    }

    static func write(entries: [LookupTableEntry], to fileURL: URL) throws {
        let capacity = slotCapacity(for: entries.count)
        var slots = Array(repeating: LookupTableEntry(hash: 0, offset: 0, length: 0), count: capacity)

        for entry in entries {
            var slot = Int(truncatingIfNeeded: entry.hash) & (capacity - 1)

            while slots[slot].length != 0 {
                slot = (slot + 1) & (capacity - 1)
            }

            slots[slot] = entry
        }

        var data = Data()
        data.append(contentsOf: magic)
        data.appendLittleEndian(version)
        data.appendLittleEndian(UInt32(capacity))
        data.appendLittleEndian(UInt32(entries.count))

        for entry in slots {
            data.appendLittleEndian(entry.hash)
            data.appendLittleEndian(entry.offset)
            data.appendLittleEndian(entry.length)
        }

        try data.write(to: fileURL, options: .atomic)
    }

    private func readEntry(at slot: Int) -> LookupTableEntry {
        let offset = Self.headerSize + (slot * Self.slotSize)
        return LookupTableEntry(
            hash: data.readLittleEndian(at: offset, as: UInt64.self),
            offset: data.readLittleEndian(at: offset + 8, as: UInt64.self),
            length: data.readLittleEndian(at: offset + 16, as: UInt32.self)
        )
    }

    private static func slotCapacity(for entryCount: Int) -> Int {
        let minimum = max(16, Int((Double(max(entryCount, 1)) / 0.7).rounded(.up)))
        var capacity = 1
        while capacity < minimum {
            capacity <<= 1
        }
        return capacity
    }
}