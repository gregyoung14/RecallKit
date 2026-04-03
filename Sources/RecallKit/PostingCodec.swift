import Foundation

enum PostingCodec {
    static func encode(_ postingList: [UInt32]) -> Data {
        var data = Data()
        var previous: UInt32 = 0

        for (index, value) in postingList.enumerated() {
            let delta = index == 0 ? value : value &- previous
            appendVarint(delta, to: &data)
            previous = value
        }

        return data
    }

    static func decode(_ data: Data, offset: Int, length: Int) -> [UInt32] {
        guard length > 0 else {
            return []
        }

        let end = offset + length
        var cursor = offset
        var values: [UInt32] = []
        var current: UInt32 = 0

        while cursor < end {
            let delta = readVarint(from: data, cursor: &cursor)
            current = current &+ delta
            values.append(current)
        }

        return values
    }

    private static func appendVarint(_ value: UInt32, to data: inout Data) {
        var remaining = value

        while remaining >= 0x80 {
            data.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }

        data.append(UInt8(remaining))
    }

    private static func readVarint(from data: Data, cursor: inout Int) -> UInt32 {
        var shift: UInt32 = 0
        var value: UInt32 = 0

        while cursor < data.count {
            let byte = data[cursor]
            cursor += 1

            value |= UInt32(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }

            shift += 7
        }

        return value
    }
}