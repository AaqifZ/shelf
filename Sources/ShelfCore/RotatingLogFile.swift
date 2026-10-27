import Foundation

/// A small append-only log with one archive. Rotation preserves the active log until its archive is complete.
public enum RotatingLogFile {
    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public let detail: String
        public init(_ detail: String) { self.detail = detail }
        public var description: String { detail }
    }

    @discardableResult
    public static func append(_ text: String, to url: URL, maximumBytes: Int = 1_000_000,
                              fileManager: FileManager = .default) -> Result<Void, Problem> {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if size(of: url, fileManager: fileManager) > maximumBytes {
                try rotate(url, fileManager: fileManager)
            }
            let data = Data(text.utf8)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            return .success(())
        } catch {
            return .failure(Problem(error.localizedDescription))
        }
    }

    public static func archiveURL(for url: URL) -> URL { url.appendingPathExtension("1") }

    private static func size(of url: URL, fileManager: FileManager) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Copy first. The active log remains intact unless the archive is safely in place.
    private static func rotate(_ url: URL, fileManager: FileManager) throws {
        let archive = archiveURL(for: url)
        let staging = archive.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: url, to: staging)
            if fileManager.fileExists(atPath: archive.path) { try fileManager.removeItem(at: archive) }
            try fileManager.moveItem(at: staging, to: archive)
            try Data().write(to: url, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}
