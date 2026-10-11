import Foundation
import ShelfCore

/// Files in ~/.shelf. Plain JSON and text, so a person or an agent can read them.
enum Store {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shelf")
    static let configURL = dir.appendingPathComponent("config.json")
    static let stateURL = dir.appendingPathComponent("state.json")
    static let logURL = dir.appendingPathComponent("shelf.log")
    static let checkLogURL = dir.appendingPathComponent("check.log")

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func loadConfig() -> Config? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? decoder.decode(Config.self, from: data)
    }

    static func save(_ config: Config) { write(config, to: configURL) }
    static func save(_ state: State) { write(state, to: stateURL) }

    static func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? decoder.decode(State.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let logQueue = DispatchQueue(label: "shelf.log")
    static func log(_ message: String, to url: URL = logURL) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        // Synchronous: the CLI (`shelf check --log`) exits right after logging, and an async write would be lost.
        logQueue.sync {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Keep the log small: start over past 1 MB.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
