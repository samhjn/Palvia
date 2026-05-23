import Foundation
import AppIntents
import SwiftData

/// Wraps a `CronJob` for use as an `AppIntent` parameter so that users can
/// pick a job by name in the Shortcuts editor instead of pasting UUIDs.
struct CronJobEntity: AppEntity, Identifiable {
    let id: UUID
    let name: String
    let cronExpression: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource(
            "appIntent.entity.cronJob",
            defaultValue: "Cron Job"
        ))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(cronExpression)"
        )
    }

    static var defaultQuery = CronJobEntityQuery()
}

/// Query backing `CronJobEntity` in the Shortcuts picker. Only enabled jobs
/// are exposed — disabled ones are invisible to automations.
struct CronJobEntityQuery: EntityQuery, EnumerableEntityQuery {

    func entities(for identifiers: [CronJobEntity.ID]) async throws -> [CronJobEntity] {
        let ids = Set(identifiers)
        return await Self.fetchEnabled().filter { ids.contains($0.id) }
    }

    func suggestedEntities() async throws -> [CronJobEntity] {
        await Self.fetchEnabled()
    }

    func allEntities() async throws -> [CronJobEntity] {
        await Self.fetchEnabled()
    }

    @MainActor
    private static func fetchEnabled() -> [CronJobEntity] {
        // Skip the SwiftData fetch when files are still encrypted, otherwise
        // Shortcuts polling this query before first unlock can deadlock the
        // process on the WAL `pread`.
        guard ProtectedDataAvailability.isAvailable else { return [] }
        let ctx = ModelContext(iClawModelContainer.shared)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.name)]
        )
        guard let jobs = try? ctx.fetch(descriptor) else { return [] }
        return jobs.map {
            CronJobEntity(
                id: $0.id,
                name: $0.name,
                cronExpression: $0.cronExpression
            )
        }
    }
}
