import Foundation
import XXHash

enum StableHasher {
    static func hash(bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBufferPointer(hash(bufferPointer:))
    }

    static func hash(bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.withUnsafeBufferPointer(hash(bufferPointer:))
    }

    private static func hash(bufferPointer: UnsafeBufferPointer<UInt8>) -> UInt64 {
        guard let baseAddress = bufferPointer.baseAddress, !bufferPointer.isEmpty else {
            return 1
        }

        var hasher = XXH3()
        hasher.update(
            bufferPointer: UnsafeRawBufferPointer(
                start: baseAddress,
                count: bufferPointer.count
            )
        )

        let digest = hasher.finalize()
        let hash = digest.bytes.reduce(into: UInt64.zero) { partial, byte in
            partial = (partial << 8) | UInt64(byte)
        }

        return hash == 0 ? 1 : hash
    }
}