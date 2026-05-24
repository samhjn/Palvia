import Foundation
import SwiftData

struct CompressionResult {
    let newCompressedContext: String
    let newCompressedUpToIndex: Int
}

final class SessionCompressor {
    let compressionThreshold: Int

    init(compressionThreshold: Int = ContextManager.compressionThreshold) {
        self.compressionThreshold = compressionThreshold
    }

    func shouldCompress(session: Session) -> Bool {
        let contextManager = ContextManager()
        let active = contextManager.activeContextTokens(session: session)
        return active > compressionThreshold
    }

    /// Performs the LLM call and returns the result without modifying the session.
    /// Returns `nil` if compression was not needed, failed, or was cancelled.
    ///
    /// When a previous compressed context exists, it is included in the prompt so
    /// the LLM produces a single unified summary rather than a naive append.
    @MainActor
    func compress(
        session: Session,
        llmService: LLMService
    ) async -> CompressionResult? {
        let tag = "[Compress:\(session.id.uuidString.prefix(6))]"
        let sorted = session.sortedMessages
        let startIdx = session.compressedUpToIndex
        let totalMessages = sorted.count

        print("\(tag) Start — totalMessages=\(totalMessages) compressedUpTo=\(startIdx)")

        guard totalMessages > startIdx + 4 else {
            print("\(tag) Skip: not enough messages (need >\(startIdx + 4), have \(totalMessages))")
            return nil
        }

        let endIdx = totalMessages - 3
        guard endIdx > startIdx else {
            print("\(tag) Skip: endIdx(\(endIdx)) <= startIdx(\(startIdx))")
            return nil
        }

        let messagesToCompress = Array(sorted[startIdx..<endIdx])
        let transcript = formatTranscript(messagesToCompress)
        let transcriptTokens = TokenEstimator.estimate(transcript)

        let existingContext = session.compressedContext ?? ""
        let existingTokens = TokenEstimator.estimate(existingContext)

        print("\(tag) Compressing \(messagesToCompress.count) messages [\(startIdx)..<\(endIdx)], transcriptTokens=\(transcriptTokens), existingContextTokens=\(existingTokens)")

        let existingBlock = existingContext.isEmpty ? "" : """

        Existing Summary:
        \(existingContext)

        """

        let compressionPrompt = """
        You are a conversation compressor for an AI agent system. \
        \(existingContext.isEmpty ? "Compress the following conversation transcript." : "Below is an existing summary followed by new messages. Produce a SINGLE unified summary that merges both.") \
        Do not duplicate information.

        Your output MUST use exactly this structure:

        ### Active Directives
        List ALL user instructions, commands, preferences, constraints, and standing orders that are STILL IN EFFECT. \
        These are things the user told the assistant to do or follow going forward. \
        Be explicit and complete — omitting a directive means the assistant will stop following it. \
        If no directives exist, write "None."

        ### Task State
        Describe the current task or goal the user is working toward. \
        What has been completed, what is in progress, what is pending. \
        Include any specific parameters, filenames, URLs, IDs, or technical details needed to continue.

        ### Key Context
        Summarize important facts, decisions, outcomes, and technical context. \
        Be concise but preserve details the assistant needs to give coherent, informed responses.
        \(existingBlock)
        Conversation:
        \(transcript)
        """

        let promptTokens = TokenEstimator.estimate(compressionPrompt)
        print("\(tag) Compression prompt ≈\(promptTokens) tokens, model=\(llmService.provider.modelName), maxOutputTokens=\(llmService.provider.maxTokens)")

        do {
            let messages: [LLMChatMessage] = [
                .system("You compress conversations into structured summaries. Always output the three required sections: Active Directives, Task State, Key Context. Never omit sections."),
                .user(compressionPrompt)
            ]

            let response = try await llmService.chatCompletion(messages: messages)

            guard !Task.isCancelled else {
                print("\(tag) Cancelled after LLM call")
                return nil
            }

            let finishReason = response.choices.first?.finishReason ?? "(none)"
            print("\(tag) LLM returned — choices=\(response.choices.count), finishReason=\(finishReason)")

            guard let summary = response.choices.first?.message?.content, !summary.isEmpty else {
                let raw = response.choices.first?.message?.content
                print("\(tag) FAIL: LLM returned empty content (raw=\(raw == nil ? "nil" : "empty string"), finishReason=\(finishReason))")
                return nil
            }

            let summaryTokens = TokenEstimator.estimate(summary)

            // Guard 1: reject trivially empty responses (< 30 tokens)
            if summaryTokens < 30 {
                print("\(tag) FAIL: Summary trivially short — \(summaryTokens) tokens")
                print("\(tag) Summary: \(summary)")
                return nil
            }

            // Guard 2: check the summary has at least one expected section header,
            // meaning the LLM followed the structured format rather than
            // producing a random/irrelevant response.
            let hasStructure = summary.contains("### Active Directives")
                || summary.contains("### Task State")
                || summary.contains("### Key Context")
            if !hasStructure {
                print("\(tag) WARN: Summary missing expected section headers, accepting anyway — \(summaryTokens) tokens")
            }

            print("\(tag) OK — summaryTokens=\(summaryTokens), newCompressedUpToIndex=\(endIdx)")

            return CompressionResult(
                newCompressedContext: summary,
                newCompressedUpToIndex: endIdx
            )
        } catch {
            print("\(tag) FAIL: LLM error — \(error)")
            return nil
        }
    }

    /// Atomically commits a compression result to the session.
    @MainActor
    func commit(
        result: CompressionResult,
        to session: Session,
        modelContext: ModelContext
    ) {
        session.compressedContext = result.newCompressedContext
        session.compressedUpToIndex = result.newCompressedUpToIndex
        session.updatedAt = Date()
        try? modelContext.save()
    }

    @MainActor
    func autoGenerateTitleIfNeeded(
        session: Session,
        llmService: LLMService,
        modelContext: ModelContext
    ) {
        guard !session.isTitleCustomized else { return }
        Task { @MainActor in
            await self.generateTitle(for: session, llmService: llmService, modelContext: modelContext)
        }
    }

    @MainActor
    private func generateTitle(
        for session: Session,
        llmService: LLMService,
        modelContext: ModelContext
    ) async {
        let recentContent = session.sortedMessages
            .filter { $0.role == .user || $0.role == .assistant }
            .prefix(8)
            .compactMap { $0.content }
            .joined(separator: "\n")

        guard !recentContent.isEmpty else { return }

        let messages: [LLMChatMessage] = [
            .system("Generate a concise title (max 6 words) summarizing this conversation. Reply with only the title, nothing else. No quotes."),
            .user(recentContent)
        ]

        do {
            let response = try await llmService.chatCompletion(messages: messages)
            if let title = response.choices.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                let cleanTitle = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                session.title = String(cleanTitle.prefix(50))
                session.updatedAt = Date()
                try? modelContext.save()
            }
        } catch {
            // Title generation is best-effort
        }
    }

    private func formatTranscript(_ messages: [Message]) -> String {
        messages.compactMap { msg in
            let role = msg.role.rawValue.capitalized
            let content = msg.content ?? "(no content)"
            var line = "[\(role)] \(content)"
            if let imgData = msg.imageAttachmentsData,
               let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
               !images.isEmpty {
                let dims = images.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
                line += " [attached \(images.count) image(s): \(dims)]"
            }
            return line
        }.joined(separator: "\n\n")
    }
}
