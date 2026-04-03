import Foundation

struct GlobMatcher: Sendable {
    private let regularExpression: NSRegularExpression

    init(pattern: String, allowPathSeparators: Bool = false) throws {
        regularExpression = try NSRegularExpression(pattern: Self.regexPattern(for: pattern, allowPathSeparators: allowPathSeparators))
    }

    func matches(_ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regularExpression.firstMatch(in: candidate, range: range) != nil
    }

    private static func regexPattern(for pattern: String, allowPathSeparators: Bool) -> String {
        var regex = "^"
        let characters = Array(pattern)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    regex.append(".*")
                    index += 1
                } else {
                    regex.append(allowPathSeparators ? ".*" : "[^/]*")
                }

            case "?":
                regex.append(allowPathSeparators ? "." : "[^/]")

            case "[":
                let characterClass = consumeCharacterClass(from: characters, startingAt: index)
                regex.append(characterClass.pattern)
                index = characterClass.endIndex

            case "\\":
                if index + 1 < characters.count {
                    regex.append(NSRegularExpression.escapedPattern(for: String(characters[index + 1])))
                    index += 1
                } else {
                    regex.append("\\\\")
                }

            default:
                regex.append(NSRegularExpression.escapedPattern(for: String(character)))
            }

            index += 1
        }

        regex.append("$")
        return regex
    }

    private static func consumeCharacterClass(from characters: [Character], startingAt index: Int) -> (pattern: String, endIndex: Int) {
        var output = "["
        var currentIndex = index + 1

        if currentIndex < characters.count, characters[currentIndex] == "!" {
            output.append("^")
            currentIndex += 1
        } else if currentIndex < characters.count, characters[currentIndex] == "^" {
            output.append("\\^")
            currentIndex += 1
        }

        while currentIndex < characters.count {
            let character = characters[currentIndex]
            if character == "]" {
                output.append("]")
                return (output, currentIndex)
            }

            if character == "\\" {
                output.append("\\\\")
            } else {
                output.append(character)
            }

            currentIndex += 1
        }

        return ("\\[", index)
    }
}