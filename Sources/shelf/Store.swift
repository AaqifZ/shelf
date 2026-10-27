import Foundation
import ShelfCore

/// Files in ~/.shelf. Plain JSON and text, so a person or an agent can read them.
enum Store {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shelf")
    static let configURL = dir.appendingPathComponent("config.json")
    static let stateURL = dir.appendingPathComponent("state.json")
    static let logURL = dir.appendingPathComponent("shelf.log")
    static let checkLogURL = dir.appendingPathComponent("check.log")

    static func loadConfig() -> ConfigurationFile.Load { ConfigurationFile.load(from: configURL) }

    @discardableResult
    static func save(_ config: Config) -> Bool {
        switch ConfigurationFile.save(config, to: configURL) {
        case .success:
            return true
        case .failure(let problem):
            log("configuration was not saved: \(problem)")
            return false
        }
    }

    @discardableResult
    static func save(_ state: State) -> Bool { write(state, to: stateURL) }

    static func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log("could not write \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static let logQueue = DispatchQueue(label: "shelf.log")
    static func log(_ message: String, to url: URL = logURL) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        // Synchronous: the CLI (`shelf check --log`) exits right after logging, and an async write would be lost.
        logQueue.sync {
            if case .failure(let problem) = RotatingLogFile.append(line, to: url) {
                let error = "shelf: could not write \(url.path): \(problem)\n"
                try? FileHandle.standardError.write(contentsOf: Data(error.utf8))
            }
        }
    }
}
