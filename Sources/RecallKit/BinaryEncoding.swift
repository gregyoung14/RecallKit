import Foundation

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) -> T {
        withUnsafeBytes { rawBuffer in
            let baseAddress = rawBuffer.baseAddress!.advanced(by: offset)
            let value = baseAddress.loadUnaligned(as: T.self)
            return T(littleEndian: value)
        }
    }
}

extension UInt64 {
    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}