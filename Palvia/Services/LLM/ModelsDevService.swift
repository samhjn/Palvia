import Foundation

/// Fetches and caches the Models.dev catalog.
///
/// The catalog (`https://models.dev/api.json`) is a ~2 MB JSON blob that changes
/// slowly, so we cache it both in memory (for the lifetime of the actor) and on
/// disk (across launches) with a day-long freshness window. Callers get the
/// cached copy instantly when fresh and can force a network refresh from the UI.
actor ModelsDevService {
    static let shared = ModelsDevService()

    /// Public catalog endpoint.
    static let catalogURL = URL(string: "https://models.dev/api.json")!

    /// How long a cached catalog is considered fresh.
    private static let freshness: TimeInterval = 60 * 60 * 24 // 24h

    private var memoryCache: ModelsDevCatalog?
    private var memoryCacheDate: Date?

    private let session: URLSession
    private let cacheFileURL: URL?

    init(session: URLSession = .shared) {
        self.session = session
        self.cacheFileURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("models-dev-catalog.json")
    }

    /// Return the catalog, preferring caches unless `forceRefresh` is set.
    ///
    /// Resolution order: fresh in-memory copy → fresh on-disk copy → network.
    /// A `forceRefresh` skips both caches and re-fetches. On a network failure
    /// we fall back to any cached copy (even a stale one) so the UI degrades
    /// gracefully offline.
    func catalog(forceRefresh: Bool = false) async throws -> ModelsDevCatalog {
        if !forceRefresh {
            if let mem = memoryCache, let date = memoryCacheDate, isFresh(date) {
                return mem
            }
            if let disk = loadFromDisk(), isFresh(disk.date) {
                memoryCache = disk.catalog
                memoryCacheDate = disk.date
                return disk.catalog
            }
        }

        do {
            let catalog = try await fetchFromNetwork()
            return catalog
        } catch {
            // Network failed — serve any cached copy we have, even if stale.
            if let mem = memoryCache { return mem }
            if let disk = loadFromDisk() {
                memoryCache = disk.catalog
                memoryCacheDate = disk.date
                return disk.catalog
            }
            throw error
        }
    }

    // MARK: - Network

    private func fetchFromNetwork() async throws -> ModelsDevCatalog {
        var request = URLRequest(url: Self.catalogURL)
        request.timeoutInterval = 20
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        APIRequestBuilder.applyCommonHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        try APIRequestBuilder.validate(data: data, response: response)

        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: data)
        memoryCache = catalog
        memoryCacheDate = Date()
        saveToDisk(data)
        return catalog
    }

    // MARK: - Freshness

    private func isFresh(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) < Self.freshness
    }

    // MARK: - Disk cache

    private func loadFromDisk() -> (catalog: ModelsDevCatalog, date: Date)? {
        guard let url = cacheFileURL,
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelsDevCatalog.self, from: data)
        else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = attrs?[.modificationDate] as? Date
        return (catalog, date ?? .distantPast)
    }

    private func saveToDisk(_ data: Data) {
        guard let url = cacheFileURL else { return }
        try? data.write(to: url, options: .atomic)
    }
}
