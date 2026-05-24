import Foundation

/// Kind of a staged file, determined by the Share Extension at loadItem time.
/// Drives how the main app materializes the file into the target session's
/// compose area (image bar, video bar, or file bar).
enum HandoffFileKind: String, Codable {
    case image
    case video
    case file
    case text
}

/// One file inside a `HandoffManifest`.
struct HandoffFile: Codable, Identifiable, Hashable {
    /// Filename relative to the handoff's staging directory.
    let name: String
    let kind: HandoffFileKind
    /// Display name to show the user, if different from the on-disk name.
    let displayName: String?

    var id: String { name }
}

/// JSON manifest the Share Extension drops into each handoff directory so the
/// main app can enumerate staged files without trusting directory scanning or
/// percent-encoded filename lists in the deep-link URL.
///
/// We deliberately avoid a `Date` field here — `Date` codable strategies are
/// easy to mismatch across encoder/decoder and a silently-failing
/// `try? decoder.decode(...)` is how share handoffs silently dropped before.
/// When the main app needs a timestamp it reads the staging directory's
/// `contentModificationDate` instead.
struct HandoffManifest: Codable, Equatable {
    let version: Int
    let agentId: UUID
    let files: [HandoffFile]

    static let currentVersion = 1
    static let filename = "manifest.json"

    /// Load the manifest from a staging directory.
    ///
    /// Tolerant of minor schema drift: tries strict Codable decode first,
    /// then falls back to a permissive `JSONSerialization` parse that only
    /// requires `agentId` (UUID string) and `files` (array with `name` +
    /// `kind`). A missing or unparseable `version` is treated as the
    /// current version. Unknown extra fields are ignored. This keeps the
    /// main app resilient against older / future / partially-corrupt
    /// manifests.
    static func load(from directory: URL) -> HandoffManifest? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Primary: strict Codable decode. An empty `files` array is useless
        // — reject it here so the tolerant path and the strict path agree.
        if let m = try? JSONDecoder().decode(HandoffManifest.self, from: data),
           !m.files.isEmpty {
            return m
        }

        // Fallback: permissive parse for older manifests (including ones
        // with a legacy `createdAt` Date field in any encoding strategy).
        return parseTolerantly(data: data)
    }

    /// Persist the manifest into a staging directory.
    func write(to directory: URL) throws {
        let url = directory.appendingPathComponent(HandoffManifest.filename)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Tolerant fallback

    /// Parse a manifest from raw bytes using JSONSerialization, extracting
    /// only the fields we strictly need. Unknown keys are ignored; a wrong
    /// date format anywhere in the payload is not fatal.
    static func parseTolerantly(data: Data) -> HandoffManifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let agentIdStr = json["agentId"] as? String,
              let agentId = UUID(uuidString: agentIdStr) else {
            return nil
        }
        guard let rawFiles = json["files"] as? [[String: Any]] else {
            return nil
        }
        let files: [HandoffFile] = rawFiles.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty,
                  let kindStr = dict["kind"] as? String,
                  let kind = HandoffFileKind(rawValue: kindStr) else {
                return nil
            }
            let display = dict["displayName"] as? String
            return HandoffFile(name: name, kind: kind, displayName: display)
        }
        guard !files.isEmpty else { return nil }
        let version = (json["version"] as? Int) ?? currentVersion
        return HandoffManifest(version: version, agentId: agentId, files: files)
    }
}
