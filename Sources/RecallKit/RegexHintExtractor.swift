struct RegexHintExtractor: Sendable {
    func literalHints(from pattern: String) -> [String] {
        guard shouldUseLiteralPrefilter(for: pattern) else {
            return []
        }

        var hints: [String] = []
        var current = ""
        var isEscaped = false

        for character in pattern {
            if isEscaped {
                if isRegexCharacterClassEscape(character) {
                    flush(&current, into: &hints)
                } else {
                    current.append(character)
                }

                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if ".^$*+".contains(character) {
                flush(&current, into: &hints)
                continue
            }

            current.append(character)
        }

        flush(&current, into: &hints)

        var seen: Set<String> = []
        return hints.filter { seen.insert($0).inserted }
    }

    private func shouldUseLiteralPrefilter(for pattern: String) -> Bool {
        let characters = Array(pattern)
        var isEscaped = false

        for index in characters.indices {
            let character = characters[index]

            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if "[]{}()|?".contains(character) {
                return false
            }

            if character == "*" || character == "+" {
                guard index > 0, characters[index - 1] == "." else {
                    return false
                }
            }
        }

        return true
    }

    private func isRegexCharacterClassEscape(_ character: Character) -> Bool {
        "dDsSwWbBAZzG".contains(character) || character.isNumber
    }

    private func flush(_ current: inout String, into hints: inout [String]) {
        if current.count >= 2 {
            hints.append(current)
        }
        current = ""
    }
}