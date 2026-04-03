import Foundation

struct DirectoryCrawler: Sendable {
    let configuration: IndexConfiguration

    func collectFiles(at rootURL: URL) throws -> [URL] {
        let ignoreMatcher = try IgnoreMatcher(rootURL: rootURL, configuration: configuration)
        var files: [URL] = []

        try walk(directoryURL: rootURL.standardizedFileURL, rootURL: rootURL.standardizedFileURL, ignoreMatcher: ignoreMatcher, files: &files)

        return files.sorted { $0.path < $1.path }
    }

    private func walk(directoryURL: URL, rootURL: URL, ignoreMatcher: IgnoreMatcher, files: inout [URL]) throws {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let childURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsSubdirectoryDescendants]
        ).sorted { $0.path < $1.path }

        for childURL in childURLs {
            let values = try childURL.resourceValues(forKeys: resourceKeys)
            let name = childURL.lastPathComponent
            let isHidden = name.hasPrefix(".")
            let relativePath = childURL.relativePath(from: rootURL)
            let isDirectory = values.isDirectory == true
            let isRegularFile = values.isRegularFile == true
            let isSymbolicLink = values.isSymbolicLink == true

            if !configuration.includeHiddenFiles && isHidden && !configuration.ignoreFileNames.contains(name) {
                continue
            }

            if isDirectory {
                if shouldSkipDirectory(named: name) || ignoreMatcher.ignores(relativePath: relativePath, isDirectory: true) {
                    continue
                }

                try walk(directoryURL: childURL, rootURL: rootURL, ignoreMatcher: ignoreMatcher, files: &files)
                continue
            }

            if isSymbolicLink && !configuration.followSymlinks {
                continue
            }

            guard isRegularFile || (configuration.followSymlinks && isSymbolicLink) else {
                continue
            }

            if ignoreMatcher.ignores(relativePath: relativePath, isDirectory: false) {
                continue
            }

            if let fileSize = values.fileSize, fileSize > configuration.maxFileSize {
                continue
            }

            if try isIndexableTextFile(at: childURL) {
                files.append(childURL)
            }
        }
    }

    private func shouldSkipDirectory(named name: String) -> Bool {
        configuration.skippedDirectoryNames.contains(name)
    }

    private func isIndexableTextFile(at fileURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let prefix = try handle.read(upToCount: 1024) ?? Data()
        return !prefix.contains(where: { $0 == 0 })
    }
}