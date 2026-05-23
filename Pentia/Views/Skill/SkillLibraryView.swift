import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct SkillLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var skills: [Skill] = []
    @State private var searchText = ""
    @State private var showCreateSheet = false

    // MARK: - Import flow state
    //
    // Multi-step flow: security confirmation → folder picker → outcome
    // dispatch → optional warnings/collision confirm → commit. Each step
    // owns a `@State` flag; presented sheets/alerts read shared payload
    // from `pendingImport`.

    @State private var showImportSecurityAlert = false
    @State private var showFolderPicker = false
    @State private var pendingImport: SkillImporter.Outcome?
    @State private var pendingSourceURL: URL?
    @State private var importErrorMessage: String?
    @State private var showImportErrorAlert = false
    @State private var showImportSuccess = false
    @State private var importedSkillName: String?

    var body: some View {
        NavigationStack {
            Group {
                if filteredSkills.isEmpty && searchText.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.Skills.noSkills, systemImage: "sparkles")
                    } description: {
                        Text(L10n.Skills.noSkillsDescription)
                    } actions: {
                        Button(L10n.Skills.createSkill) { showCreateSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if filteredSkills.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    skillList
                }
            }
            .navigationTitle(L10n.Skills.title)
            .searchable(text: $searchText, prompt: L10n.Skills.searchSkills)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showCreateSheet = true
                        } label: {
                            Label(L10n.Skills.createSkill, systemImage: "plus.circle")
                        }
                        Button {
                            // Security warning ALWAYS comes before the file
                            // picker — imported skills carry executable JS.
                            showImportSecurityAlert = true
                        } label: {
                            Label(L10n.Skills.importSkill, systemImage: "tray.and.arrow.down")
                        }
                        Divider()
                        Button {
                            openSkillsFolderInFiles()
                        } label: {
                            Label(L10n.Skills.showInFiles, systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                SkillEditView { reload() }
            }
            // ── Security confirmation (gate before the file picker) ─────
            .alert(L10n.Skills.importSecurityTitle, isPresented: $showImportSecurityAlert) {
                Button(L10n.Common.cancel, role: .cancel) {}
                Button(L10n.Skills.importContinue, role: .destructive) {
                    showFolderPicker = true
                }
            } message: {
                Text(L10n.Skills.importSecurityBody)
            }
            // ── Folder picker (system file importer) ────────────────────
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderPickerResult(result)
            }
            // ── Outcome dispatch: split into per-variant alerts so each
            // ── uses the modern (non-deprecated) .alert(_:isPresented:…) API.
            .alert(L10n.Skills.importFailedTitle, isPresented: bindingForFailedOutcome()) {
                Button(L10n.Common.confirm, role: .cancel) { pendingImport = nil }
            } message: {
                Text(failedOutcomeMessage())
            }
            .alert(L10n.Skills.importWarningsTitle, isPresented: bindingForWarningsOutcome()) {
                Button(L10n.Common.cancel, role: .cancel) { pendingImport = nil }
                Button(L10n.Skills.importContinue, role: .destructive) {
                    let replace = collidesIfReady()
                    performCommit(replaceExisting: replace)
                }
            } message: {
                Text(warningsOutcomeMessage())
            }
            .alert(L10n.Skills.importCollisionTitle, isPresented: bindingForCollisionOutcome()) {
                Button(L10n.Common.cancel, role: .cancel) { pendingImport = nil }
                Button(L10n.Skills.importReplace, role: .destructive) {
                    performCommit(replaceExisting: true)
                }
            } message: {
                Text(collisionOutcomeMessage())
            }
            .alert(L10n.Skills.importFailedTitle, isPresented: $showImportErrorAlert) {
                Button(L10n.Common.confirm, role: .cancel) { importErrorMessage = nil }
            } message: {
                Text(importErrorMessage ?? "")
            }
            .alert(L10n.Skills.importedTitle, isPresented: $showImportSuccess) {
                Button(L10n.Common.confirm, role: .cancel) { importedSkillName = nil }
            } message: {
                Text(L10n.Skills.importedBody(importedSkillName ?? ""))
            }
            .onAppear {
                ensureBuiltIns()
                reload()
            }
        }
    }

    // MARK: - Import flow

    private func handleFolderPickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let source = urls.first else { return }
            // The picker returns a security-scoped URL — must call
            // startAccessingSecurityScopedResource around any read of it.
            // We copy out via SkillImporter, which takes care of FileManager
            // operations within the scope below.
            let didStart = source.startAccessingSecurityScopedResource()
            defer { if didStart { source.stopAccessingSecurityScopedResource() } }
            pendingSourceURL = source
            pendingImport = SkillImporter.prepareImport(sourceURL: source, modelContext: modelContext)
            // For .ready with no collision, commit immediately.
            if case .ready(_, _, let collision) = pendingImport, collision == nil {
                performCommit(replaceExisting: false)
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
            showImportErrorAlert = true
        }
    }

    /// True when the pending outcome is `.notADirectory`, `.error`, or a
    /// `.ready` whose collision is built-in (built-ins refuse replacement).
    /// All three render as the failure alert with a different message.
    private func bindingForFailedOutcome() -> Binding<Bool> {
        Binding(
            get: {
                switch pendingImport {
                case .notADirectory, .error: return true
                case .ready(_, _, let collision?): return collision.isBuiltIn
                default: return false
                }
            },
            set: { if !$0 { pendingImport = nil } }
        )
    }

    private func bindingForWarningsOutcome() -> Binding<Bool> {
        Binding(
            get: {
                if case .warningsRequireConfirmation = pendingImport { return true }
                return false
            },
            set: { if !$0 { pendingImport = nil } }
        )
    }

    private func bindingForCollisionOutcome() -> Binding<Bool> {
        Binding(
            get: {
                if case .ready(_, _, let collision?) = pendingImport, !collision.isBuiltIn {
                    return true
                }
                return false
            },
            set: { if !$0 { pendingImport = nil } }
        )
    }

    private func failedOutcomeMessage() -> String {
        switch pendingImport {
        case .notADirectory: return L10n.Skills.importNotADirectory
        case .error(let report): return formatErrorReport(report)
        case .ready(_, _, let collision?): return L10n.Skills.importBuiltInRefused(collision.name)
        default: return ""
        }
    }

    private func warningsOutcomeMessage() -> String {
        guard case .warningsRequireConfirmation(_, let report, let collision) = pendingImport else {
            return ""
        }
        var msg = formatWarningsBody(report)
        if let c = collision {
            msg += "\n\n" + L10n.Skills.importCollisionFooter(c.name)
        }
        return msg
    }

    private func collisionOutcomeMessage() -> String {
        guard case .ready(_, _, let collision?) = pendingImport else { return "" }
        return L10n.Skills.importCollisionBody(collision.name)
    }

    /// True when the pending `.ready` outcome carries a non-built-in
    /// collision — used to set `replaceExisting` for the warnings-confirm
    /// branch (warnings + collision both true → user has confirmed both).
    private func collidesIfReady() -> Bool {
        switch pendingImport {
        case .warningsRequireConfirmation(_, _, let collision):
            return collision != nil && collision?.isBuiltIn == false
        default:
            return false
        }
    }

    private func performCommit(replaceExisting: Bool) {
        guard let outcome = pendingImport else { return }
        do {
            let skill = try SkillImporter.commitImport(
                outcome: outcome,
                replaceExisting: replaceExisting,
                modelContext: modelContext
            )
            importedSkillName = skill.effectiveDisplayName
            showImportSuccess = true
            pendingImport = nil
            reload()
        } catch {
            importErrorMessage = error.localizedDescription
            showImportErrorAlert = true
            pendingImport = nil
        }
    }

    private func formatErrorReport(_ report: ValidationReport) -> String {
        let head = L10n.Skills.importValidationFailed(report.errors.count)
        let lines = report.errors.prefix(8).map { "• \($0.file):\($0.line) — \($0.message)" }
        return ([head] + lines).joined(separator: "\n")
    }

    private func formatWarningsBody(_ report: ValidationReport) -> String {
        let head = L10n.Skills.importValidationWarnings(report.warnings.count)
        let lines = report.warnings.prefix(6).map { "• \($0.file):\($0.line) — \($0.message)" }
        return ([head] + lines).joined(separator: "\n")
    }

    private var filteredSkills: [Skill] {
        if searchText.isEmpty { return skills }
        let q = searchText.lowercased()
        return skills.filter {
            $0.name.lowercased().contains(q) ||
            $0.effectiveDisplayName.lowercased().contains(q) ||
            $0.summary.lowercased().contains(q) ||
            $0.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private var skillList: some View {
        List {
            let builtIn = filteredSkills.filter { $0.isBuiltIn }
            let custom = filteredSkills.filter { !$0.isBuiltIn }

            if !custom.isEmpty {
                Section(L10n.Skills.customSkills) {
                    ForEach(custom, id: \.id) { skill in
                        NavigationLink {
                            SkillDetailView(skill: skill, onDelete: { reload() })
                        } label: {
                            SkillRowView(skill: skill)
                        }
                    }
                }
            }

            if !builtIn.isEmpty {
                Section(L10n.Skills.builtInSkills) {
                    ForEach(builtIn, id: \.id) { skill in
                        NavigationLink {
                            SkillDetailView(skill: skill, onDelete: nil)
                        } label: {
                            SkillRowView(skill: skill)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func reload() {
        let service = SkillService(modelContext: modelContext)
        skills = service.fetchAllSkills()
    }

    private func ensureBuiltIns() {
        let service = SkillService(modelContext: modelContext)
        service.ensureBuiltInSkills()
        // Pick up any package dropped into <Documents>/Skills/ while the app
        // was foregrounded (Files.app, zip extraction). Cheap when there's
        // nothing new — a directory listing + per-folder slug lookup.
        service.discoverDiskPackages()
    }

    /// Open the iOS Files app at `<Documents>/Skills/` via the
    /// `shareddocuments://` URL scheme. The directory is created eagerly at
    /// launch (LaunchTaskManager) so this always lands somewhere valid —
    /// even when the user has no skills yet, the empty folder appears.
    private func openSkillsFolderInFiles() {
        let path = AgentFileManager.shared.skillsRoot.path
        guard let url = URL(string: "shareddocuments://" + path) else { return }
        UIApplication.shared.open(url)
    }
}

struct SkillRowView: View {
    let skill: Skill
    @State private var packageStatus: PackageStatus = .unknown

    /// Result of validating the on-disk package backing this skill row.
    /// Drives the small status badge next to the row title.
    enum PackageStatus {
        case unknown          // not yet computed (or no on-disk package — legacy SwiftData-only skill)
        case ok               // validates with no errors and no warnings
        case warnings(Int)    // validates but the validator flagged some warnings
        case errors(Int)      // validation failed; skill row is running on last-good cache
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(skill.effectiveDisplayName)
                    .font(.headline)
                Spacer()
                statusBadge
                if skill.isBuiltIn {
                    Text(L10n.Skills.builtIn)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.blue.opacity(0.15)))
                        .foregroundStyle(.blue)
                }
            }

            Text(skill.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if !skill.tags.isEmpty {
                    ForEach(skill.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.secondary.opacity(0.12)))
                    }
                }
                Spacer()
                if skill.installCount > 0 {
                    Label("\(skill.installCount)", systemImage: "cpu")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .task { computePackageStatus() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch packageStatus {
        case .unknown:
            EmptyView()
        case .ok:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .warnings(let n):
            Label("\(n)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .errors(let n):
            Label("\(n)", systemImage: "xmark.octagon.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    /// Validate the on-disk package backing this row (if any) and update the
    /// status badge. Built-ins always validate (their bundle source is
    /// shipped-tested) so we shortcut to .ok without a parse pass. User
    /// skills without a package fall through to .unknown — they're legacy
    /// SwiftData-only rows that pre-date Phase 4 and don't have a directory
    /// to validate against.
    private func computePackageStatus() {
        if skill.isBuiltIn {
            packageStatus = .ok
            return
        }
        let slug = SkillPackage.derivedSlug(forName: skill.name)
        let url = AgentFileManager.shared.skillsRoot.appendingPathComponent(slug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            packageStatus = .unknown
            return
        }
        let report = SkillPackage.validate(at: url)
        if !report.errors.isEmpty {
            packageStatus = .errors(report.errors.count)
        } else if !report.warnings.isEmpty {
            packageStatus = .warnings(report.warnings.count)
        } else {
            packageStatus = .ok
        }
    }
}
