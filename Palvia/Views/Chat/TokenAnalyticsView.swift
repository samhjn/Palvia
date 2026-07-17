import SwiftUI

/// A sheet presenting aggregated token usage for a chat session: vendor-billed
/// input/output/cache counts plus a local estimate of context composition by
/// role and current context-window utilisation.
struct TokenAnalyticsView: View {
    let stats: TokenStatistics
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if stats.hasAPIUsage {
                    billedSection
                }
                if stats.hasEstimatedUsage {
                    estimatedUsageSection
                } else if !stats.hasAPIUsage {
                    noUsageSection
                }
                compositionSection
                if stats.hasPerTurnOverhead {
                    overheadSection
                }
                contextSection
            }
            .navigationTitle(L10n.TokenStats.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Billed

    private var billedSection: some View {
        Section {
            statRow(label: L10n.TokenStats.input,
                    value: stats.billedInputTokens,
                    systemImage: "arrow.down.circle",
                    tint: .blue)
            statRow(label: L10n.TokenStats.output,
                    value: stats.billedOutputTokens,
                    systemImage: "arrow.up.circle",
                    tint: .green)
            statRow(label: L10n.TokenStats.total,
                    value: stats.billedTotalTokens,
                    systemImage: "sum",
                    tint: .primary,
                    emphasized: true)

            if stats.hasCacheActivity {
                statRow(label: L10n.TokenStats.cacheRead,
                        value: stats.cacheReadTokens,
                        systemImage: "bolt.horizontal.circle",
                        tint: .teal)
                statRow(label: L10n.TokenStats.cacheWrite,
                        value: stats.cacheWriteTokens,
                        systemImage: "square.and.arrow.down",
                        tint: .orange)
            }

            plainRow(label: L10n.TokenStats.avgOutputPerTurn,
                     value: TokenStatistics.format(stats.averageOutputPerTurn))
        } header: {
            Text(L10n.TokenStats.sectionBilled)
        } footer: {
            Text("\(L10n.TokenStats.billedNote) · \(L10n.TokenStats.turnsWithUsage(stats.turnsWithUsage))")
        }
    }

    private var noUsageSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(L10n.TokenStats.noUsage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.TokenStats.sectionBilled)
        }
    }

    private var estimatedUsageSection: some View {
        Section {
            statRow(label: L10n.TokenStats.input,
                    value: stats.fallbackInputTokens,
                    systemImage: "arrow.down.circle",
                    tint: .blue)
            statRow(label: L10n.TokenStats.output,
                    value: stats.fallbackOutputTokens,
                    systemImage: "arrow.up.circle",
                    tint: .green)
            statRow(label: L10n.TokenStats.total,
                    value: stats.fallbackTotalTokens,
                    systemImage: "sum",
                    tint: .primary,
                    emphasized: true)
        } header: {
            Text(L10n.TokenStats.sectionEstimatedUsage)
        } footer: {
            Text("\(L10n.TokenStats.estimatedUsageNote) · \(L10n.TokenStats.turnsWithEstimatedUsage(stats.turnsWithEstimatedUsage))")
        }
    }

    // MARK: - Composition

    private var compositionSection: some View {
        Section {
            CompositionBar(stats: stats)
                .padding(.vertical, 4)

            compositionRow(label: L10n.TokenStats.roleUser, value: stats.userTokens, color: .blue)
            compositionRow(label: L10n.TokenStats.roleAssistant, value: stats.assistantTokens, color: .green)
            compositionRow(label: L10n.TokenStats.roleTool, value: stats.toolTokens, color: .orange)
            if stats.systemTokens > 0 {
                compositionRow(label: L10n.TokenStats.roleSystem, value: stats.systemTokens, color: .purple)
            }

            statRow(label: L10n.TokenStats.estimatedTotal,
                    value: stats.estimatedTotalTokens,
                    systemImage: "doc.text.magnifyingglass",
                    tint: .primary,
                    emphasized: true)
        } header: {
            Text(L10n.TokenStats.sectionComposition)
        } footer: {
            Text("\(L10n.TokenStats.estimatedNote) · \(L10n.TokenStats.messages(stats.messageCount))")
        }
    }

    // MARK: - Per-turn overhead

    private var overheadSection: some View {
        Section {
            statRow(label: L10n.TokenStats.systemPrompt,
                    value: stats.systemPromptTokens,
                    systemImage: "text.alignleft",
                    tint: .purple)
            if stats.configMarkdownTokens > 0 {
                subRow(label: L10n.TokenStats.configMarkdown, value: stats.configMarkdownTokens)
            }
            if stats.skillsTokens > 0 {
                subRow(label: L10n.TokenStats.skills, value: stats.skillsTokens)
            }
            if stats.toolSchemaTokens > 0 {
                statRow(label: L10n.TokenStats.toolSchemas,
                        value: stats.toolSchemaTokens,
                        systemImage: "wrench.and.screwdriver",
                        tint: .indigo)
            }
            statRow(label: L10n.TokenStats.total,
                    value: stats.perTurnOverheadTokens,
                    systemImage: "sum",
                    tint: .primary,
                    emphasized: true)
        } header: {
            Text(L10n.TokenStats.sectionOverhead)
        } footer: {
            Text(L10n.TokenStats.overheadNote)
        }
    }

    // MARK: - Context window

    private var contextSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.TokenStats.activeContext)
                    Spacer()
                    Text(L10n.Chat.tokenUsage(active: TokenStatistics.format(stats.activeContextTokens),
                                              threshold: TokenStatistics.format(stats.contextThreshold)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.systemGray5))
                        Capsule()
                            .fill(contextColor(stats.contextUsageRatio))
                            .frame(width: geo.size.width * min(CGFloat(stats.contextUsageRatio), 1.0))
                    }
                }
                .frame(height: 6)
            }
            .padding(.vertical, 4)

            if stats.isCompressed {
                statRow(label: L10n.TokenStats.compressedSummary,
                        value: stats.compressedSummaryTokens,
                        systemImage: "arrow.down.right.and.arrow.up.left",
                        tint: .teal)
            }
        } header: {
            Text(L10n.TokenStats.sectionContext)
        } footer: {
            if stats.isCompressed {
                Text(L10n.TokenStats.compressedNote(stats.compressedMessageCount))
            }
        }
    }

    // MARK: - Rows

    private func statRow(label: String, value: Int, systemImage: String, tint: Color, emphasized: Bool = false) -> some View {
        HStack {
            Label {
                Text(label)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Spacer()
            Text(TokenStatistics.format(value))
                .fontWeight(emphasized ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
    }

    /// Indented, de-emphasized "of which" sub-item beneath a stat row.
    private func subRow(label: String, value: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
            Spacer()
            Text(TokenStatistics.format(value))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func plainRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func compositionRow(label: String, value: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(TokenStatistics.format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func contextColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.6: return .green
        case ..<0.85: return .yellow
        case ..<1.0: return .orange
        default: return .red
        }
    }
}

/// A single horizontal stacked bar showing the relative token weight of each role.
private struct CompositionBar: View {
    let stats: TokenStatistics

    private var segments: [(color: Color, value: Int)] {
        [(.blue, stats.userTokens),
         (.green, stats.assistantTokens),
         (.orange, stats.toolTokens),
         (.purple, stats.systemTokens)].filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { geo in
            let total = max(stats.estimatedTotalTokens, 1)
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: geo.size.width * CGFloat(seg.value) / CGFloat(total))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
    }
}
