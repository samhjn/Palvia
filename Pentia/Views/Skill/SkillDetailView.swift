import SwiftUI
import SwiftData
import UIKit

struct SkillDetailView: View {
    @Bindable var skill: Skill
    let onDelete: (() -> Void)?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var showDeleteConfirm = false
    @State private var showInstallSheet = false
    @State private var sharePayload: SharePayload?
    @State private var validationReport: ValidationReport?

    /// Wrapper carrying a prepared zip URL for the iOS share sheet. We use
    /// `.sheet(item:)` rather than a `Bool`+`[URL]` pair so SwiftUI presents
    /// the sheet atomically with its content, avoiding the "first share
    /// shows an empty sheet" race that the bool/items split exhibited.
    private struct SharePayload: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                Divider()
                metadataSection
                if let report = validationReport, !report.errors.isEmpty || !report.warnings.isEmpty {
                    validationSection(report)
                }
                Divider()
                contentSection
                if !skill.scripts.isEmpty {
                    Divider()
                    scriptsSection
                }
                if !skill.customTools.isEmpty {
                    Divider()
                    toolsSection
                }
            }
            .padding()
        }
        .navigationTitle(skill.effectiveDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await computeValidationReport() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showInstallSheet = true } label: {
                    Image(systemName: "cpu.fill")
                }
                Menu {
                    if !skill.isBuiltIn {
                        Button { isEditing = true } label: {
                            Label(L10n.Common.edit, systemImage: "pencil")
                        }
                    }
                    // Share / export the on-disk package via the iOS share
                    // sheet. Available for both built-ins (bundle path → we
                    // copy to a temp dir so AirDrop / Save to Files / etc.
                    // can read it) and user skills with a package. Hidden
                    // only for legacy SwiftData-only rows.
                    if packageURL != nil {
                        Button { prepareShare() } label: {
                            Label(L10n.Skills.shareSkill, systemImage: "square.and.arrow.up")
                        }
                    }
                    if !skill.isBuiltIn, hasOnDiskPackage {
                        Button { revealInFiles() } label: {
                            Label(L10n.Skills.revealInFiles, systemImage: "folder")
                        }
                    }
                    if !skill.isBuiltIn {
                        Divider()
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            SkillEditView(existingSkill: skill)
        }
        .sheet(isPresented: $showInstallSheet) {
            InstallSkillOnAgentSheet(skill: skill)
        }
        .sheet(item: $sharePayload) { payload in
            SkillShareSheet(items: [payload.url])
        }
        .alert(L10n.Skills.deleteSkill, isPresented: $showDeleteConfirm) {
            Button(L10n.Common.delete, role: .destructive) {
                SkillService(modelContext: modelContext).deleteSkill(skill)
                onDelete?()
                dismiss()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Skills.deleteSkillMessage(skill.effectiveDisplayName))
        }
    }

    /// True for user skills whose package directory exists under
    /// `<Documents>/Skills/<slug>/`. Built-ins are bundle-backed and not
    /// reachable through the iOS Files app.
    private var hasOnDiskPackage: Bool {
        guard !skill.isBuiltIn else { return false }
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let url = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// On-disk URL for the skill's package directory — bundle path for
    /// built-ins, `<Documents>/Skills/<slug>/` for user skills. Returns nil
    /// for legacy SwiftData-only rows that have no package on disk yet.
    /// Drives the ShareLink for export.
    private var packageURL: URL? {
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        if skill.isBuiltIn {
            return BuiltInSkillsDirectoryLoader.packageURL(forSlug: slug)
        }
        let url = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Open the iOS Files app at this skill's package directory using the
    /// `shareddocuments://` URL scheme. The app's `UIFileSharingEnabled`
    /// flag in Info.plist makes the path resolvable from outside.
    private func revealInFiles() {
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let path = AgentFileManager.shared.skillsRoot
            .appendingPathComponent(slug, isDirectory: true).path
        guard let url = URL(string: "shareddocuments://" + path) else { return }
        UIApplication.shared.open(url)
    }

    /// Prepare a single .zip of the package directory and present the share
    /// sheet against it.
    ///
    /// Why a zip rather than the raw directory: `UIActivityViewController`'s
    /// directory-URL handling is uneven across share targets — some
    /// extensions enumerate items themselves, others don't. The "empty
    /// share sheet" symptom on first share traced back to this, plus a
    /// `Bool`+`[URL]` binding race. A single zip is the most universally
    /// accepted format, and `NSFileCoordinator(.forUploading)` is the
    /// iOS-blessed way to get one.
    ///
    /// Runs off the main actor — for a 60-file Health Plus-shape package
    /// the zip is non-trivial sync work. State assignment hops back to
    /// MainActor and uses `.sheet(item:)` (assigned in this commit) so the
    /// sheet sees the URL atomically.
    private func prepareShare() {
        guard let src = packageURL else { return }
        Task.detached(priority: .userInitiated) {
            guard let zipped = Self.prepareShareableArchive(of: src) else { return }
            await MainActor.run {
                sharePayload = SharePayload(url: zipped)
            }
        }
    }

    /// Use NSFileCoordinator's `.forUploading` reading option — the same
    /// mechanism share extensions and AirDrop use under the hood — to
    /// produce a zip representation of `dir`. The coordinated URL is
    /// auto-cleaned when the closure returns, so we copy it to a stable
    /// temp file before letting the closure exit.
    nonisolated static func prepareShareableArchive(of dir: URL) -> URL? {
        let stem = "\(dir.lastPathComponent)-\(UUID().uuidString.prefix(8).lowercased()).zip"
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(stem)

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: dir,
            options: [.forUploading],
            error: &coordinatorError
        ) { zipURL in
            do {
                try FileManager.default.copyItem(at: zipURL, to: stable)
            } catch {
                copyError = error
            }
        }
        if let e = coordinatorError {
            print("[SkillDetailView] share coordinator failed: \(e.localizedDescription)")
            return nil
        }
        if let e = copyError {
            print("[SkillDetailView] share copy failed: \(e.localizedDescription)")
            return nil
        }
        return FileManager.default.fileExists(atPath: stable.path) ? stable : nil
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(skill.summary)
                .font(.title3)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(skill.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 20) {
            Label(skill.author, systemImage: "person")
            Label("v\(skill.version)", systemImage: "tag")
            Label("\(skill.installCount) \(L10n.Skills.agents)", systemImage: "cpu")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Skills.content)
                .font(.headline)

            // Markdown render — headings, bullet lists, and fenced code
            // blocks (with syntax highlighting via CodeBlockView).
            // Replaces the old plain-Text render that left ``code``,
            // **bold**, and # headings as raw text.
            MarkdownContentView(skill.content)
                .textSelection(.enabled)
        }
    }

    /// Show validator output inline so the agent / user can see exactly
    /// what's wrong with the package — not just an amber/red badge in the
    /// row. Computed lazily off-main on appear.
    @ViewBuilder
    private func validationSection(_ report: ValidationReport) -> some View {
        let isError = !report.errors.isEmpty
        let title = isError ? L10n.Skills.validationErrorsTitle : L10n.Skills.validationWarningsTitle
        let symbol = isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let tint: Color = isError ? .red : .orange
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.bold())
                .foregroundStyle(tint)
            ForEach(report.errors + report.warnings, id: \.self) { issue in
                HStack(alignment: .top, spacing: 6) {
                    Text(issue.severity == .error ? "✕" : "⚠")
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.message)
                            .font(.caption)
                        Text(issueLocationString(issue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.08)))
    }

    /// Format the issue's location footer: `path:line • code` (or just
    /// `path • code` for whole-file issues with line == 0).
    private func issueLocationString(_ issue: ValidationIssue) -> String {
        if issue.line > 0 {
            return "\(issue.file):\(issue.line) • \(issue.code.rawValue)"
        }
        return "\(issue.file) • \(issue.code.rawValue)"
    }

    /// One parameter row. Renders as: `name: type` (mono) + optional
    /// (optional) badge + dash + description. The HStack lets the
    /// description wrap to the next visual line via Text's natural
    /// wrapping; nothing competes for width with the leading metadata.
    @ViewBuilder
    private func parameterRow(_ param: SkillToolParam) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            (Text(param.name).foregroundStyle(.primary)
             + Text(":").foregroundStyle(.secondary)
             + Text(param.type).foregroundStyle(.orange))
                .font(.system(.caption2, design: .monospaced))
            if !param.required {
                Text(L10n.Skills.parameterOptional)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !param.description.isEmpty {
                Text("— \(param.description)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// Run the validator off the main thread on view appear. Built-ins
    /// always validate cleanly (shipped-tested) so we shortcut without
    /// touching disk; user skills with no on-disk package leave the report
    /// nil and the section stays hidden.
    private func computeValidationReport() async {
        if skill.isBuiltIn {
            // Built-ins are bundle-backed and always clean — no badge ever
            // appears for them, no need to spend cycles validating.
            return
        }
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let url = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let report = await Task.detached(priority: .userInitiated) {
            SkillPackage.validate(at: url)
        }.value
        await MainActor.run { self.validationReport = report }
    }

    @ViewBuilder
    private var scriptsSection: some View {
        if !skill.scripts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.Skills.scriptsCount(skill.scripts.count), systemImage: "terminal")
                    .font(.headline)

                ForEach(skill.scripts, id: \.name) { script in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(script.name)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(script.language)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue.opacity(0.15)))
                        }
                        if let desc = script.description {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(script.code)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        if !skill.customTools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L10n.Skills.customToolsCount(skill.customTools.count), systemImage: "wrench.and.screwdriver")
                    .font(.headline)

                ForEach(skill.customTools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tool.name)
                            .font(.subheadline.bold())
                        Text(tool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if !tool.parameters.isEmpty {
                            // One row per parameter rather than a wrapping
                            // chip strip — chip rows broke badly when a
                            // tool had 4+ params (the chip text wrapped
                            // mid-word inside each capsule, see Phase 9d).
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(L10n.Skills.parameters):")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                ForEach(tool.parameters, id: \.name) { param in
                                    parameterRow(param)
                                }
                            }
                            .padding(.top, 2)
                        }

                        Text(tool.implementation)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Share sheet wrapper

/// SwiftUI bridge to UIActivityViewController for sharing one or more URLs
/// (e.g. an exported skill package directory). UIActivityViewController
/// handles the directory→zip transformation that AirDrop / Mail / etc.
/// expect, so callers just hand it a directory URL and don't need a zip
/// helper.
struct SkillShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Install on agent sheet

struct InstallSkillOnAgentSheet: View {
    let skill: Skill
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var agents: [Agent] = []

    var body: some View {
        NavigationStack {
            List {
                if agents.isEmpty {
                    ContentUnavailableView(L10n.Skills.noAgents, systemImage: "cpu", description: Text(L10n.Skills.noAgentsDescription))
                } else {
                    ForEach(agents, id: \.id) { agent in
                        let installed = agent.installedSkills.contains { $0.skill?.id == skill.id }
                        Button {
                            let service = SkillService(modelContext: modelContext)
                            if installed {
                                _ = service.uninstallSkill(skill, from: agent)
                            } else {
                                _ = service.installSkill(skill, on: agent)
                            }
                            loadAgents()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(agent.name).font(.headline)
                                    let count = agent.activeSkills.count
                                    Text(L10n.Skills.skillsActive(count))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if installed {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle(L10n.Skills.install(skill.effectiveDisplayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
            .onAppear { loadAgents() }
        }
    }

    private func loadAgents() {
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.parentAgent == nil },
            sortBy: [SortDescriptor(\.name)]
        )
        agents = (try? modelContext.fetch(descriptor)) ?? []
    }
}

// MARK: - Create / Edit

struct SkillEditView: View {
    var existingSkill: Skill?
    var onSave: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var summary = ""
    @State private var content = ""
    @State private var tagsText = ""
    @State private var scripts: [SkillScript] = []
    @State private var customTools: [SkillToolDefinition] = []

    // Editing state for new script
    @State private var showAddScript = false
    @State private var newScriptName = ""
    @State private var newScriptDesc = ""
    @State private var newScriptCode = ""
    /// Non-nil when the script sheet is editing an existing entry.
    @State private var editingScriptIndex: Int?

    // Editing state for new tool
    @State private var showAddTool = false
    @State private var newToolName = ""
    @State private var newToolDesc = ""
    @State private var newToolCode = ""
    @State private var newToolParams: [SkillToolParam] = []
    /// Non-nil when the tool sheet is editing an existing entry.
    @State private var editingToolIndex: Int?

    init(existingSkill: Skill? = nil, onSave: (() -> Void)? = nil) {
        self.existingSkill = existingSkill
        self.onSave = onSave
    }

    private var isEditing: Bool { existingSkill != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.Skills.info) {
                    TextField(L10n.Skills.skillName, text: $name)
                    TextField(L10n.Skills.summary, text: $summary)
                    TextField(L10n.Skills.tags, text: $tagsText)
                        .autocapitalization(.none)
                }

                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 200)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text(L10n.Skills.contentMarkdown)
                } footer: {
                    Text(L10n.Skills.contentFooter)
                }

                // Scripts section
                Section {
                    ForEach(Array(scripts.enumerated()), id: \.element.name) { index, script in
                        // Whole-row Button → tap opens the edit sheet
                        // prefilled with the existing script. The previous
                        // layout used an inline destructive Button which
                        // List/Form picked up as the row's primary tap
                        // target — tapping the row deleted the script
                        // instead of editing it.
                        Button {
                            editingScriptIndex = index
                            newScriptName = script.name
                            newScriptDesc = script.description ?? ""
                            newScriptCode = script.code
                            showAddScript = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(script.name).font(.subheadline.bold())
                                if let desc = script.description, !desc.isEmpty {
                                    Text(desc).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(script.code)
                                    .font(.system(.caption2, design: .monospaced))
                                    .lineLimit(3)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                scripts.remove(at: index)
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        editingScriptIndex = nil
                        newScriptName = ""
                        newScriptDesc = ""
                        newScriptCode = ""
                        showAddScript = true
                    } label: {
                        Label(L10n.Skills.addScript, systemImage: "plus")
                    }
                } header: {
                    Label(L10n.Skills.scripts, systemImage: "terminal")
                } footer: {
                    Text(L10n.Skills.scriptsFooter)
                }

                // Custom Tools section
                Section {
                    ForEach(Array(customTools.enumerated()), id: \.element.name) { index, tool in
                        // Whole-row Button → opens the edit sheet prefilled.
                        // Same fix as scripts above; the inline destructive
                        // button used to absorb every row tap.
                        Button {
                            editingToolIndex = index
                            newToolName = tool.name
                            newToolDesc = tool.description
                            newToolCode = tool.implementation
                            newToolParams = tool.parameters
                            showAddTool = true
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tool.name).font(.subheadline.bold())
                                Text(tool.description).font(.caption).foregroundStyle(.secondary)
                                if !tool.parameters.isEmpty {
                                    Text("Params: \(tool.parameters.map { $0.name }.joined(separator: ", "))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                customTools.remove(at: index)
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        editingToolIndex = nil
                        newToolName = ""
                        newToolDesc = ""
                        newToolCode = ""
                        newToolParams = []
                        showAddTool = true
                    } label: {
                        Label(L10n.Skills.addTool, systemImage: "plus")
                    }
                } header: {
                    Label(L10n.Skills.customTools, systemImage: "wrench.and.screwdriver")
                } footer: {
                    Text(L10n.Skills.customToolsFooter)
                }
            }
            .navigationTitle(isEditing ? L10n.Skills.editSkill : L10n.Skills.newSkill)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        save()
                        dismiss()
                    }
                    .disabled(name.isEmpty || content.isEmpty)
                }
            }
            .onAppear {
                if let s = existingSkill {
                    name = s.name
                    summary = s.summary
                    content = s.content
                    tagsText = s.tags.joined(separator: ", ")
                    scripts = s.scripts
                    customTools = s.customTools
                }
            }
            .sheet(isPresented: $showAddScript) {
                addScriptSheet
            }
            .sheet(isPresented: $showAddTool) {
                addToolSheet
            }
        }
    }

    // MARK: - Add / Edit Script Sheet
    //
    // Dual-mode: appends a new script when `editingScriptIndex == nil`,
    // replaces the entry at that index otherwise. The row Buttons in the
    // scripts Section set the index before flipping showAddScript on.

    private var addScriptSheet: some View {
        NavigationStack {
            Form {
                Section(L10n.Skills.info) {
                    TextField(L10n.Skills.scriptName, text: $newScriptName)
                        .autocapitalization(.none)
                    TextField(L10n.Skills.descriptionOptional, text: $newScriptDesc)
                }
                Section(L10n.Skills.jsCode) {
                    TextEditor(text: $newScriptCode)
                        .frame(minHeight: 200)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .navigationTitle(editingScriptIndex == nil ? L10n.Skills.addScript : L10n.Skills.editScriptTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        editingScriptIndex = nil
                        showAddScript = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingScriptIndex == nil ? L10n.Common.add : L10n.Common.save) {
                        let script = SkillScript(
                            name: newScriptName,
                            code: newScriptCode,
                            description: newScriptDesc.isEmpty ? nil : newScriptDesc
                        )
                        if let idx = editingScriptIndex, scripts.indices.contains(idx) {
                            scripts[idx] = script
                        } else {
                            scripts.append(script)
                        }
                        editingScriptIndex = nil
                        showAddScript = false
                    }
                    .disabled(newScriptName.isEmpty || newScriptCode.isEmpty)
                }
            }
        }
    }

    // MARK: - Add Tool Sheet

    private var addToolSheet: some View {
        NavigationStack {
            Form {
                Section(L10n.Skills.toolInfo) {
                    TextField(L10n.Skills.toolName, text: $newToolName)
                        .autocapitalization(.none)
                    TextField(L10n.Skills.description, text: $newToolDesc)
                }
                Section {
                    ForEach(Array(newToolParams.enumerated()), id: \.offset) { index, _ in
                        HStack {
                            TextField("Name", text: Binding(
                                get: { newToolParams[index].name },
                                set: { newToolParams[index] = SkillToolParam(name: $0, type: newToolParams[index].type, description: newToolParams[index].description, required: newToolParams[index].required) }
                            ))
                            .autocapitalization(.none)
                            .frame(maxWidth: 100)
                            Picker("", selection: Binding(
                                get: { newToolParams[index].type },
                                set: { newToolParams[index] = SkillToolParam(name: newToolParams[index].name, type: $0, description: newToolParams[index].description, required: newToolParams[index].required) }
                            )) {
                                Text("string").tag("string")
                                Text("number").tag("number")
                                Text("boolean").tag("boolean")
                            }
                            .labelsHidden()
                            .frame(maxWidth: 90)
                            Button(role: .destructive) {
                                newToolParams.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                        }
                    }
                    Button {
                        newToolParams.append(SkillToolParam(name: "", description: ""))
                    } label: {
                        Label(L10n.Skills.addParameter, systemImage: "plus")
                    }
                } header: {
                    Text(L10n.Skills.parameters)
                }
                Section {
                    TextEditor(text: $newToolCode)
                        .frame(minHeight: 200)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text(L10n.Skills.jsImplementation)
                } footer: {
                    Text(L10n.Skills.jsImplementationFooter)
                }
            }
            .navigationTitle(editingToolIndex == nil ? L10n.Skills.addTool : L10n.Skills.editToolTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        editingToolIndex = nil
                        showAddTool = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingToolIndex == nil ? L10n.Common.add : L10n.Common.save) {
                        let validParams = newToolParams.filter { !$0.name.isEmpty }
                        let tool = SkillToolDefinition(
                            name: newToolName,
                            description: newToolDesc,
                            parameters: validParams,
                            implementation: newToolCode
                        )
                        if let idx = editingToolIndex, customTools.indices.contains(idx) {
                            customTools[idx] = tool
                        } else {
                            customTools.append(tool)
                        }
                        editingToolIndex = nil
                        showAddTool = false
                    }
                    .disabled(newToolName.isEmpty || newToolCode.isEmpty)
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        let tags = tagsText.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let service = SkillService(modelContext: modelContext)

        // Track the old slug so a rename can clean up the previous on-disk
        // package directory after writing the new one.
        let oldSlug: String? = existingSkill.map { SkillPackage.derivedSlug(forName: $0.name) }

        let skill: Skill
        if let s = existingSkill {
            service.updateSkill(s, name: name, summary: summary, content: content, tags: tags)
            s.scripts = scripts
            s.customTools = customTools
            try? modelContext.save()
            skill = s
        } else {
            skill = service.createSkill(
                name: name, summary: summary, content: content, tags: tags,
                scripts: scripts, customTools: customTools
            )
        }

        // Phase 8b: mirror the row to <Documents>/Skills/<slug>/ so the
        // directory remains the source of truth that fs.* writes and the
        // auto-reload pipeline expect. Built-in slugs are excluded — the
        // UI never lets the user edit built-ins, but defensive in case.
        let newSlug = SkillPackage.derivedSlug(forName: skill.name)
        if !newSlug.isEmpty, !BuiltInSkills.shippedSlugs.contains(newSlug) {
            let root = AgentFileManager.shared.skillsRoot
            let dest = root.appendingPathComponent(newSlug, isDirectory: true)

            // Rename: remove the previous slug's directory before writing
            // the new one. Skip if the renamed slug collides with a built-in
            // (shouldn't happen; defensive).
            if let old = oldSlug, !old.isEmpty, old != newSlug,
               !BuiltInSkills.shippedSlugs.contains(old) {
                let oldDest = root.appendingPathComponent(old, isDirectory: true)
                try? FileManager.default.removeItem(at: oldDest)
            }

            do {
                try SkillPackage.write(skill, to: dest)
            } catch {
                // Best-effort mirroring: if serialization fails (e.g. a tool
                // name with hyphens that the writer rejects), the row still
                // persists in SwiftData, so the skill works through the
                // legacy cache path. Log for diagnosis.
                print("[SkillEditView] failed to mirror '\(skill.name)' to disk: \(error.localizedDescription)")
            }
        }

        onSave?()
    }
}
