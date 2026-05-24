import SwiftUI
import SwiftData

struct AgentToolPermissionsView: View {
    @Bindable var agent: Agent
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            Section {
                Text(L10n.ToolPermissions.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text(L10n.ToolPermissions.appleSection)) {
                ForEach(ToolCategory.appleCategories, id: \.self) { category in
                    CategoryPermissionRow(agent: agent, category: category) {
                        try? modelContext.save()
                    }
                }
            }

            Section(header: Text(L10n.ToolPermissions.agentSection)) {
                ForEach(ToolCategory.agentCategories, id: \.self) { category in
                    CategoryPermissionRow(agent: agent, category: category) {
                        try? modelContext.save()
                    }
                }
            }

            Section {
                Button(L10n.ApplePermissions.enableAll) {
                    agent.appleToolPermissionsRaw = nil
                    try? modelContext.save()
                }
                Button(L10n.ApplePermissions.readOnlyAll) {
                    var perms: [String: ToolPermissionLevel] = [:]
                    for cat in ToolCategory.allCases {
                        if cat.hasWriteTools {
                            perms[cat.rawValue] = .readOnly
                        }
                    }
                    agent.toolPermissions = perms
                    try? modelContext.save()
                }
                Button(L10n.ApplePermissions.disableAll, role: .destructive) {
                    var perms: [String: ToolPermissionLevel] = [:]
                    for cat in ToolCategory.allCases {
                        perms[cat.rawValue] = .disabled
                    }
                    agent.toolPermissions = perms
                    try? modelContext.save()
                }
            }
        }
        .navigationTitle(L10n.ToolPermissions.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CategoryPermissionRow: View {
    @Bindable var agent: Agent
    let category: ToolCategory
    let onSave: () -> Void

    private var currentLevel: ToolPermissionLevel {
        agent.permissionLevel(for: category)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.title2)
                .foregroundStyle(colorForLevel(currentLevel))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .font(.headline)
                Text(permissionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { currentLevel },
                set: { newLevel in
                    agent.setPermissionLevel(newLevel, for: category)
                    onSave()
                }
            )) {
                ForEach(category.availableLevels, id: \.self) { level in
                    Text(level.displayLabel).tag(level)
                }
            }
            .pickerStyle(.menu)
            .tint(colorForLevel(currentLevel))
        }
        .padding(.vertical, 4)
    }

    private var permissionSummary: String {
        let readCount = category.readToolNames.count
        let writeCount = category.writeToolNames.count
        switch currentLevel {
        case .readWrite:
            return L10n.ApplePermissions.summaryReadWrite(readCount + writeCount)
        case .readOnly:
            return L10n.ApplePermissions.summaryReadOnly(readCount)
        case .writeOnly:
            return L10n.ApplePermissions.summaryWriteOnly(writeCount)
        case .disabled:
            return L10n.ApplePermissions.summaryDisabled
        }
    }

    private func colorForLevel(_ level: ToolPermissionLevel) -> Color {
        switch level {
        case .readWrite: return .green
        case .readOnly:  return .blue
        case .writeOnly: return .orange
        case .disabled:  return .gray
        }
    }
}
