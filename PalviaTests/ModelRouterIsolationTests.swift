import XCTest
import SwiftData
@testable import Palvia

/// Regression tests for a TestFlight crash (SIGABRT inside
/// `ModelContext.fetch`): `ModelRouter`'s async failover methods used to be
/// nonisolated, so in the Swift 5 language mode they hopped to the global
/// concurrent executor and ran `modelContext.fetch` on a background thread,
/// racing the main thread's concurrent use of the same ModelContext.
///
/// The methods are now `@MainActor`, and ModelRouter's fetch helpers assert
/// main-thread execution in debug builds. These tests drive the full provider
/// resolution path through the async entry points; if the `@MainActor`
/// isolation is ever removed again, the assertion aborts the test run.
final class ModelRouterIsolationTests: XCTestCase {

    private let schema = Schema([
        Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
        CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
        Message.self, SessionEmbedding.self
    ])

    @MainActor
    private func makeAgentAndRouter() throws -> (Agent, ModelRouter) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let agent = Agent(name: "IsolationAgent")
        context.insert(agent)
        try context.save()
        return (agent, ModelRouter(modelContext: context))
    }

    /// With no providers configured, the failover call walks the entire
    /// resolution path (`fetchProvider`/`fetchGlobalDefault`, i.e. real
    /// `ModelContext.fetch` calls) and then throws — no network involved.
    @MainActor
    func testStreamFailoverResolvesProvidersOnMainThread() async throws {
        let (agent, router) = try makeAgentAndRouter()

        do {
            _ = try await router.chatCompletionStreamWithFailover(
                agent: agent, messages: [], tools: nil
            )
            XCTFail("Expected ChatError.noProviderConfigured")
        } catch let error as ChatError {
            guard case .noProviderConfigured = error else {
                XCTFail("Expected noProviderConfigured, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testNonStreamingFailoverResolvesProvidersOnMainThread() async throws {
        let (agent, router) = try makeAgentAndRouter()

        do {
            _ = try await router.chatCompletionWithFailover(
                agent: agent, messages: [], tools: nil
            )
            XCTFail("Expected ChatError.noProviderConfigured")
        } catch let error as ChatError {
            guard case .noProviderConfigured = error else {
                XCTFail("Expected noProviderConfigured, got \(error)")
                return
            }
        }
    }
}
