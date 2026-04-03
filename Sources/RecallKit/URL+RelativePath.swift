import Foundation

extension URL {
    func relativePath(from rootURL: URL) -> String {
        let standardizedRoot = rootURL.standardizedFileURL.path
        let standardizedPath = standardizedFileURL.path

        guard standardizedPath.hasPrefix(standardizedRoot) else {
            return lastPathComponent
        }

        let relative = standardizedPath.dropFirst(standardizedRoot.count)
        if relative.hasPrefix("/") {
            return String(relative.dropFirst())
        }

        return String(relative)
    }
}