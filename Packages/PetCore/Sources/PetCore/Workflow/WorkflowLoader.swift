import Foundation
import Yams

public enum WorkflowLoaderError: Error {
    case fileNotFound(URL)
    case decodingFailed(String)
    case encodingFailed(String)
}

public struct WorkflowLoader: Sendable {
    public init() {}

    public func load(from url: URL) throws -> Workflow {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkflowLoaderError.fileNotFound(url)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try loadFromString(raw)
    }

    public func loadFromString(_ yaml: String) throws -> Workflow {
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(Workflow.self, from: yaml)
        } catch {
            throw WorkflowLoaderError.decodingFailed(String(describing: error))
        }
    }

    public func save(_ workflow: Workflow, to url: URL) throws {
        let encoder = YAMLEncoder()
        encoder.options.indent = 2
        encoder.options.sortKeys = false
        do {
            let yaml = try encoder.encode(workflow)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try yaml.write(to: url, atomically: true, encoding: .utf8)
        } catch let e as WorkflowLoaderError {
            throw e
        } catch {
            throw WorkflowLoaderError.encodingFailed(String(describing: error))
        }
    }
}
