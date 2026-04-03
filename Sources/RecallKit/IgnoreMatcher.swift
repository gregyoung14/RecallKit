import Foundation

struct IgnoreMatcher: Sendable {
    private let rules: [IgnoreRule]

    init(rootURL: URL, configuration: IndexConfiguration) throws {
        if configuration.respectIgnoreFiles {
            rules = try Self.loadRules(at: rootURL, rootURL: rootURL, configuration: configuration)
        } else {
            rules = []
        }
    }

    func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false

        for rule in rules where rule.matches(relativePath: relativePath, isDirectory: isDirectory) {
            ignored = !rule.isNegated
        }

        return ignored
    }

    private static func loadRules(at directoryURL: URL, rootURL: URL, configuration: IndexConfiguration) throws -> [IgnoreRule] {
        var collectedRules: [IgnoreRule] = []
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]

        let childURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsSubdirectoryDescendants]
        )

        for ignoreFileName in configuration.ignoreFileNames {
            let ignoreFileURL = directoryURL.appendingPathComponent(ignoreFileName)
            guard fileManager.fileExists(atPath: ignoreFileURL.path) else {
                continue
            }

            let relativeBasePath = directoryURL.relativePath(from: rootURL)
            let fileContents = try String(contentsOf: ignoreFileURL, encoding: .utf8)
            for line in fileContents.split(whereSeparator: \ .isNewline) {
                if let rule = try IgnoreRule(line: String(line), basePath: relativeBasePath) {
                    collectedRules.append(rule)
                }
            }
        }

        for childURL in childURLs.sorted(by: { $0.path < $1.path }) {
            let values = try childURL.resourceValues(forKeys: resourceKeys)
            guard values.isDirectory == true else {
                continue
            }

            let directoryName = childURL.lastPathComponent
            if configuration.skippedDirectoryNames.contains(directoryName) {
                continue
            }

            if !configuration.includeHiddenFiles && directoryName.hasPrefix(".") && !configuration.ignoreFileNames.contains(directoryName) {
                continue
            }

            collectedRules.append(contentsOf: try loadRules(at: childURL, rootURL: rootURL, configuration: configuration))
        }

        return collectedRules
    }
}

private struct IgnoreRule: Sendable {
    let basePath: String
    let isNegated: Bool
    let directoryOnly: Bool
    let basenameOnly: Bool
    let matcher: GlobMatcher

    init?(line: String, basePath: String) throws {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("\\#") {
            trimmed.removeFirst()
        } else if trimmed.hasPrefix("#") {
            return nil
        }

        var isNegated = false
        if trimmed.hasPrefix("\\!") {
            trimmed.removeFirst()
        } else if trimmed.hasPrefix("!") {
            isNegated = true
            trimmed.removeFirst()
        }

        guard !trimmed.isEmpty else { return nil }

        var directoryOnly = false
        if trimmed.hasSuffix("/") {
            directoryOnly = true
            trimmed.removeLast()
        }

        let anchored = trimmed.hasPrefix("/")
        if anchored {
            trimmed.removeFirst()
        }

        let basenameOnly = !trimmed.contains("/")
        let normalizedBasePath = basePath == "." ? "" : basePath
        self.basePath = normalizedBasePath
        self.isNegated = isNegated
        self.directoryOnly = directoryOnly
        self.basenameOnly = basenameOnly
        self.matcher = try GlobMatcher(pattern: trimmed, allowPathSeparators: !basenameOnly)
    }

    func matches(relativePath path: String, isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory {
            return false
        }

        guard let relativeToBase = relativePath(candidate: path, under: basePath) else {
            return false
        }

        if basenameOnly {
            return matcher.matches(URL(fileURLWithPath: relativeToBase).lastPathComponent)
        }

        return matcher.matches(relativeToBase)
    }

    private func relativePath(candidate: String, under basePath: String) -> String? {
        guard !basePath.isEmpty else {
            return candidate
        }

        if candidate == basePath {
            return ""
        }

        let prefix = basePath + "/"
        guard candidate.hasPrefix(prefix) else {
            return nil
        }

        return String(candidate.dropFirst(prefix.count))
    }
}