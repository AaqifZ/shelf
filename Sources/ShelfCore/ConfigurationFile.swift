import Foundation

/// Reads and writes the layout memory without hiding filesystem or JSON failures.
public enum ConfigurationFile {
    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        case invalidExistingFile(String)
        case cannotCreateDirectory(String)
        case cannotEncode(String)
        case cannotWrite(String)

        public var description: String {
            switch self {
            case .unreadable(let detail): "cannot read: \(detail)"
            case .malformed(let detail): "invalid JSON: \(detail)"
            case .invalidExistingFile(let detail): "existing configuration is unsafe to replace: \(detail)"
            case .cannotCreateDirectory(let detail): "cannot create directory: \(detail)"
            case .cannotEncode(let detail): "cannot encode: \(detail)"
            case .cannotWrite(let detail): "cannot write: \(detail)"
            }
        }
    }

    public enum Load: Equatable, Sendable {
        case missing
        case loaded(Config)
        case failed(Problem)
    }

    /// Missing is a valid first-run state. An existing file that cannot be read or decoded is a failure.
    public static func load(from url: URL) -> Load {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return .missing }
            return .failed(.unreadable(error.localizedDescription))
        }
        do {
            return .loaded(try decoder().decode(Config.self, from: data))
        } catch {
            return .failed(.malformed(error.localizedDescription))
        }
    }

    /// Writes atomically. A malformed or unreadable existing file is preserved for diagnosis and recovery.
    @discardableResult
    public static func save(_ config: Config, to url: URL, fileManager: FileManager = .default) -> Result<Void, Problem> {
        if case .failed(let problem) = load(from: url) {
            return .failure(.invalidExistingFile(problem.description))
        }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure(.cannotCreateDirectory(error.localizedDescription))
        }
        let data: Data
        do {
            data = try encoder().encode(config)
        } catch {
            return .failure(.cannotEncode(error.localizedDescription))
        }
        do {
            try data.write(to: url, options: .atomic)
            return .success(())
        } catch {
            return .failure(.cannotWrite(error.localizedDescription))
        }
    }

    /// Encoders and decoders are created per operation. Foundation does not promise shared instances are thread-safe.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
