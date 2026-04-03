import Foundation

indirect enum QueryPlan: Sendable, Equatable, Hashable {
    case scanAll
    case lookup(UInt64)
    case and([QueryPlan])
    case or([QueryPlan])
}

private indirect enum ParsedPlan: Equatable {
    case scanAll
    case literal(String)
    case and([ParsedPlan])
    case or([ParsedPlan])
}

struct RegexQueryPlanner: Sendable {
    func plan(for pattern: String, configuration: IndexConfiguration = .default) -> QueryPlan {
        var parser = Parser(pattern: Array(pattern))
        let extractor = SparseNGramExtractor(maxNGramLength: configuration.maxNGramLength)

        return simplify(
            materialize(
                parser.parse(),
                extractor: extractor,
                limit: configuration.maxCoveringNGrams
            )
        )
    }

    func candidates(
        for pattern: String,
        in index: SearchIndex,
        configuration: SearchConfiguration
    ) -> [UInt32] {
        guard configuration.useLiteralPrefilter else {
            return index.documents.map(\ .id)
        }

        let plan = plan(for: pattern, configuration: index.configuration)
        let allDocuments = Set(index.documents.map(\ .id))
        return execute(plan, in: index, allDocuments: allDocuments).sorted()
    }

    private func materialize(
        _ plan: ParsedPlan,
        extractor: SparseNGramExtractor,
        limit: Int
    ) -> QueryPlan {
        switch plan {
        case .scanAll:
            return .scanAll

        case let .literal(literal):
            let hashes = extractor.coveringHashes(for: literal, limit: limit)
            switch hashes.count {
            case 0:
                return .scanAll
            case 1:
                return .lookup(hashes[0])
            default:
                return .and(hashes.map(QueryPlan.lookup))
            }

        case let .and(children):
            let convertedChildren = children
                .map { materialize($0, extractor: extractor, limit: limit) }
                .filter { $0 != .scanAll }

            switch convertedChildren.count {
            case 0:
                return .scanAll
            case 1:
                return convertedChildren[0]
            default:
                return .and(convertedChildren)
            }

        case let .or(children):
            let convertedChildren = children.map { materialize($0, extractor: extractor, limit: limit) }
            if convertedChildren.contains(.scanAll) {
                return .scanAll
            }

            return convertedChildren.count == 1 ? convertedChildren[0] : .or(convertedChildren)
        }
    }

    private func execute(
        _ plan: QueryPlan,
        in index: SearchIndex,
        allDocuments: Set<UInt32>
    ) -> Set<UInt32> {
        switch plan {
        case .scanAll:
            return allDocuments

        case let .lookup(hash):
            return Set(index.postings(for: hash))

        case let .and(children):
            let narrowedChildren = children.filter { $0 != .scanAll }
            guard let firstChild = narrowedChildren.first else {
                return allDocuments
            }

            var result = execute(firstChild, in: index, allDocuments: allDocuments)

            for child in narrowedChildren.dropFirst() {
                result.formIntersection(execute(child, in: index, allDocuments: allDocuments))
                if result.isEmpty {
                    break
                }
            }

            return result

        case let .or(children):
            if children.contains(.scanAll) {
                return allDocuments
            }

            return children.reduce(into: Set<UInt32>()) { partial, child in
                partial.formUnion(execute(child, in: index, allDocuments: allDocuments))
            }
        }
    }

    private func simplify(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        case .scanAll, .lookup:
            return plan

        case let .and(children):
            let simplifiedChildren = children.map(simplify)
            var flattened: [QueryPlan] = []

            for child in simplifiedChildren {
                switch child {
                case .scanAll:
                    continue
                case let .and(nestedChildren):
                    flattened.append(contentsOf: nestedChildren)
                default:
                    flattened.append(child)
                }
            }

            var seen: Set<QueryPlan> = []
            let uniqueChildren = flattened.filter { seen.insert($0).inserted }
            switch uniqueChildren.count {
            case 0:
                return .scanAll
            case 1:
                return uniqueChildren[0]
            default:
                return .and(uniqueChildren)
            }

        case let .or(children):
            let simplifiedChildren = children.map(simplify)
            if simplifiedChildren.contains(.scanAll) {
                return .scanAll
            }

            var flattened: [QueryPlan] = []
            for child in simplifiedChildren {
                if case let .or(nestedChildren) = child {
                    flattened.append(contentsOf: nestedChildren)
                } else {
                    flattened.append(child)
                }
            }

            var seen: Set<QueryPlan> = []
            let uniqueChildren = flattened.filter { seen.insert($0).inserted }
            switch uniqueChildren.count {
            case 0:
                return .scanAll
            case 1:
                return uniqueChildren[0]
            default:
                return .or(uniqueChildren)
            }
        }
    }
}

private struct Parser {
    private let pattern: [Character]
    private var index = 0

    init(pattern: [Character]) {
        self.pattern = pattern
    }

    mutating func parse() -> ParsedPlan {
        simplify(parseAlternation())
    }

    private mutating func parseAlternation() -> ParsedPlan {
        var branches = [parseConcatenation()]

        while consume("|") {
            branches.append(parseConcatenation())
        }

        return branches.count == 1 ? branches[0] : .or(branches)
    }

    private mutating func parseConcatenation() -> ParsedPlan {
        var parts: [ParsedPlan] = []

        while let next = peek(), next != ")", next != "|" {
            let atom = parseAtom()
            parts.append(parseQuantifierIfPresent(for: atom))
        }

        return concatenate(parts)
    }

    private mutating func parseAtom() -> ParsedPlan {
        guard let next = peek() else {
            return .scanAll
        }

        switch next {
        case "(":
            advance()
            if consume("?") {
                if consume(":") {
                    let nested = parseAlternation()
                    _ = consume(")")
                    return nested
                }

                skipUntilGroupClose()
                return .scanAll
            }

            let nested = parseAlternation()
            _ = consume(")")
            return nested

        case "[":
            skipCharacterClass()
            return .scanAll

        case ".", "^", "$":
            advance()
            return .scanAll

        case "\\":
            advance()
            guard let escaped = peek() else {
                return .scanAll
            }
            advance()

            if isRegexClassEscape(escaped) {
                return .scanAll
            }

            return .literal(String(escaped))

        default:
            advance()
            return .literal(String(next))
        }
    }

    private mutating func parseQuantifierIfPresent(for atom: ParsedPlan) -> ParsedPlan {
        guard let next = peek() else {
            return atom
        }

        switch next {
        case "?", "*":
            advance()
            return .scanAll

        case "+":
            advance()
            return atom

        case "{":
            return parseBraceQuantifier(for: atom)

        default:
            return atom
        }
    }

    private mutating func parseBraceQuantifier(for atom: ParsedPlan) -> ParsedPlan {
        let quantifierStart = index
        advance()

        let minimumDigits = consumeDigits()
        guard !minimumDigits.isEmpty else {
            skipInvalidBraceQuantifier(from: quantifierStart)
            return .scanAll
        }

        let minimum = Int(minimumDigits) ?? 0

        if consume(",") {
            _ = consumeDigits()
        }

        guard consume("}") else {
            skipInvalidBraceQuantifier(from: quantifierStart)
            return .scanAll
        }

        return minimum == 0 ? .scanAll : atom
    }

    private mutating func consumeDigits() -> String {
        var digits = ""

        while let next = peek(), next.isNumber {
            digits.append(next)
            advance()
        }

        return digits
    }

    private mutating func skipInvalidBraceQuantifier(from start: Int) {
        index = start
        advance()
        while let next = peek(), next != "}" {
            advance()
        }
        _ = consume("}")
    }

    private mutating func skipCharacterClass() {
        advance()
        var isEscaped = false

        while let next = peek() {
            advance()

            if isEscaped {
                isEscaped = false
                continue
            }

            if next == "\\" {
                isEscaped = true
                continue
            }

            if next == "]" {
                return
            }
        }
    }

    private mutating func skipUntilGroupClose() {
        var depth = 1
        var isEscaped = false

        while let next = peek(), depth > 0 {
            advance()

            if isEscaped {
                isEscaped = false
                continue
            }

            if next == "\\" {
                isEscaped = true
                continue
            }

            if next == "(" {
                depth += 1
            } else if next == ")" {
                depth -= 1
            }
        }
    }

    private func concatenate(_ parts: [ParsedPlan]) -> ParsedPlan {
        var merged: [ParsedPlan] = []
        var literalBuffer = ""

        func flushLiteralBuffer() {
            guard !literalBuffer.isEmpty else {
                return
            }

            merged.append(.literal(literalBuffer))
            literalBuffer = ""
        }

        for part in parts.map(simplify) {
            switch part {
            case .scanAll:
                flushLiteralBuffer()
                continue

            case let .literal(literal):
                literalBuffer.append(literal)

            case let .and(children):
                flushLiteralBuffer()
                merged.append(contentsOf: children)

            case .or:
                flushLiteralBuffer()
                merged.append(part)
            }
        }

        flushLiteralBuffer()

        switch merged.count {
        case 0:
            return .scanAll
        case 1:
            return merged[0]
        default:
            return .and(merged)
        }
    }

    private func simplify(_ plan: ParsedPlan) -> ParsedPlan {
        switch plan {
        case .scanAll, .literal:
            return plan

        case let .and(children):
            let simplifiedChildren = children.map(simplify)
            var flattened: [ParsedPlan] = []

            for child in simplifiedChildren {
                switch child {
                case .scanAll:
                    continue
                case let .and(nestedChildren):
                    flattened.append(contentsOf: nestedChildren)
                default:
                    flattened.append(child)
                }
            }

            switch flattened.count {
            case 0:
                return .scanAll
            case 1:
                return flattened[0]
            default:
                return .and(flattened)
            }

        case let .or(children):
            let simplifiedChildren = children.map(simplify)
            if simplifiedChildren.contains(.scanAll) {
                return .scanAll
            }

            var flattened: [ParsedPlan] = []
            for child in simplifiedChildren {
                if case let .or(nestedChildren) = child {
                    flattened.append(contentsOf: nestedChildren)
                } else {
                    flattened.append(child)
                }
            }

            var uniqueChildren: [ParsedPlan] = []
            for child in flattened where !uniqueChildren.contains(child) {
                uniqueChildren.append(child)
            }

            return uniqueChildren.count == 1 ? uniqueChildren[0] : .or(uniqueChildren)
        }
    }

    private func isRegexClassEscape(_ character: Character) -> Bool {
        "dDsSwWbBAZzGpP".contains(character) || character.isNumber
    }

    private func peek() -> Character? {
        guard index < pattern.count else {
            return nil
        }

        return pattern[index]
    }

    @discardableResult
    private mutating func consume(_ character: Character) -> Bool {
        guard peek() == character else {
            return false
        }

        index += 1
        return true
    }

    private mutating func advance() {
        index += 1
    }
}