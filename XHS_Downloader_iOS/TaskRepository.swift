import Foundation
import SwiftData

@Model
final class StoredDownloadTask {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model
final class RepositoryMarker {
    @Attribute(.unique) var key: String
    var value: String
    init(key: String, value: String) { self.key = key; self.value = value }
}

@ModelActor
actor TaskRepository {
    func load(legacyURL: URL) throws -> [DownloadTaskRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let markers = try modelContext.fetch(FetchDescriptor<RepositoryMarker>())
        if !markers.contains(where: { $0.key == "legacy-import-v1" }) {
            do {
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    let data = try Data(contentsOf: legacyURL)
                    let tasks = try decoder.decode([DownloadTaskRecord].self, from: data)
                    let backup = legacyURL.deletingLastPathComponent().appendingPathComponent("before-swiftdata-v1.json")
                    if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
                    try stageReplacement(tasks)
                }
                // Rows and migration marker commit together. A failed save must
                // not leave pending changes for a later unrelated save to commit.
                modelContext.insert(RepositoryMarker(key: "legacy-import-v1", value: "complete"))
                try modelContext.save()
            } catch {
                modelContext.rollback()
                throw error
            }
        }
        return try modelContext.fetch(FetchDescriptor<StoredDownloadTask>()).map {
            try decoder.decode(DownloadTaskRecord.self, from: $0.payload)
        }
    }

    func replace(_ tasks: [DownloadTaskRecord]) throws {
        do {
            try stageReplacement(tasks)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func stageReplacement(_ tasks: [DownloadTaskRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // Encode before mutating the context, including duplicate legacy IDs.
        let payloads = try Dictionary(tasks.map { ($0.id, try encoder.encode($0)) }, uniquingKeysWith: { _, last in last })
        let existing = try modelContext.fetch(FetchDescriptor<StoredDownloadTask>())
        let lookup = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for (id, data) in payloads {
            if let row = lookup[id] {
                if row.payload != data { row.payload = data }
            } else { modelContext.insert(StoredDownloadTask(id: id, payload: data)) }
        }
        for row in existing where payloads[row.id] == nil { modelContext.delete(row) }
    }
}
