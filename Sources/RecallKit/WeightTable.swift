public struct WeightTable: Sendable {
    private static let lowerClass: UInt8 = 0
    private static let upperClass: UInt8 = 1
    private static let digitClass: UInt8 = 2
    private static let spaceClass: UInt8 = 3
    private static let punctuationClass: UInt8 = 4
    private static let controlClass: UInt8 = 5
    private static let nonASCIIClass: UInt8 = 6

    private let table: [UInt32]

    public static let `default` = WeightTable()

    public init(seed: UInt64 = 0) {
        _ = seed
        var generated = Array(repeating: UInt32.zero, count: 256 * 256)

        for lhs in 0..<256 {
            for rhs in 0..<256 {
                generated[(lhs << 8) | rhs] = Self.computeWeight(UInt8(lhs), UInt8(rhs))
            }
        }

        table = generated
    }

    public func weight(_ lhs: UInt8, _ rhs: UInt8) -> UInt32 {
        table[(Int(lhs) << 8) | Int(rhs)]
    }

    private static func computeWeight(_ lhs: UInt8, _ rhs: UInt8) -> UInt32 {
        let base: UInt32

        switch (characterClass(of: lhs), characterClass(of: rhs)) {
        case (lowerClass, lowerClass):
            base = lowercasePairBase(lhs, rhs)
        case (lowerClass, spaceClass), (spaceClass, lowerClass):
            base = 15
        case (spaceClass, spaceClass):
            base = 5
        case (lowerClass, upperClass):
            base = 100
        case (upperClass, lowerClass):
            base = 40
        case (upperClass, upperClass):
            base = 60
        case (digitClass, digitClass):
            base = 80
        case (lowerClass, digitClass), (digitClass, lowerClass):
            base = 70
        case (upperClass, digitClass), (digitClass, upperClass):
            base = 75
        case (punctuationClass, lowerClass), (lowerClass, punctuationClass):
            base = 120
        case (punctuationClass, upperClass), (upperClass, punctuationClass):
            base = 130
        case (punctuationClass, punctuationClass):
            base = 140
        case (punctuationClass, spaceClass), (spaceClass, punctuationClass):
            base = 90
        case (spaceClass, upperClass), (upperClass, spaceClass):
            base = 50
        case (spaceClass, digitClass), (digitClass, spaceClass):
            base = 60
        case (digitClass, punctuationClass), (punctuationClass, digitClass):
            base = 110
        case (nonASCIIClass, nonASCIIClass):
            base = 230
        case (nonASCIIClass, _), (_, nonASCIIClass):
            base = 220
        case (controlClass, controlClass):
            base = 200
        case (controlClass, _), (_, controlClass):
            base = 180
        default:
            base = 100
        }

        let adjusted = lhs == rhs ? (base * 7) / 10 : base
        return min(max(adjusted, 1), 251)
    }

    private static func characterClass(of byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"):
            return lowerClass
        case UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return upperClass
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return digitClass
        case 32, 9, 10, 13:
            return spaceClass
        case 0...31, 127:
            return controlClass
        case 128...255:
            return nonASCIIClass
        default:
            return punctuationClass
        }
    }

    private static func lowercasePairBase(_ lhs: UInt8, _ rhs: UInt8) -> UInt32 {
        let rank = lowercasePairRank(lhs, rhs)
        if rank > 0 {
            return 3 + rank
        }

        let hash = ((UInt32(lhs) &* 7) ^ (UInt32(rhs) &* 13)) % 20
        return 30 + hash
    }

    private static func lowercasePairRank(_ lhs: UInt8, _ rhs: UInt8) -> UInt32 {
        switch (lhs, rhs) {
        case (UInt8(ascii: "t"), UInt8(ascii: "h")):
            return 1
        case (UInt8(ascii: "h"), UInt8(ascii: "e")):
            return 2
        case (UInt8(ascii: "i"), UInt8(ascii: "n")):
            return 3
        case (UInt8(ascii: "e"), UInt8(ascii: "r")):
            return 4
        case (UInt8(ascii: "a"), UInt8(ascii: "n")):
            return 5
        case (UInt8(ascii: "r"), UInt8(ascii: "e")):
            return 6
        case (UInt8(ascii: "o"), UInt8(ascii: "n")):
            return 7
        case (UInt8(ascii: "a"), UInt8(ascii: "t")):
            return 8
        case (UInt8(ascii: "e"), UInt8(ascii: "n")):
            return 9
        case (UInt8(ascii: "n"), UInt8(ascii: "d")):
            return 10
        case (UInt8(ascii: "t"), UInt8(ascii: "i")):
            return 11
        case (UInt8(ascii: "e"), UInt8(ascii: "s")):
            return 12
        case (UInt8(ascii: "e"), UInt8(ascii: "t")):
            return 12
        case (UInt8(ascii: "o"), UInt8(ascii: "r")):
            return 13
        case (UInt8(ascii: "t"), UInt8(ascii: "e")):
            return 14
        case (UInt8(ascii: "s"), UInt8(ascii: "t")):
            return 14
        case (UInt8(ascii: "o"), UInt8(ascii: "f")):
            return 15
        case (UInt8(ascii: "r"), UInt8(ascii: "n")):
            return 15
        case (UInt8(ascii: "e"), UInt8(ascii: "d")):
            return 16
        case (UInt8(ascii: "n"), UInt8(ascii: "g")):
            return 16
        case (UInt8(ascii: "i"), UInt8(ascii: "s")):
            return 17
        case (UInt8(ascii: "l"), UInt8(ascii: "e")):
            return 17
        case (UInt8(ascii: "i"), UInt8(ascii: "t")):
            return 18
        case (UInt8(ascii: "u"), UInt8(ascii: "n")):
            return 18
        case (UInt8(ascii: "a"), UInt8(ascii: "l")):
            return 19
        case (UInt8(ascii: "a"), UInt8(ascii: "r")):
            return 20
        case (UInt8(ascii: "c"), UInt8(ascii: "t")):
            return 20
        default:
            return 0
        }
    }
}