import SwiftUI
import SwiftData

struct CronJobListView: View {
    let agent: Agent
    @Environment(\.modelContext) private var modelContext
    @State private var showAddSheet = false
    @State private var showShortcutsGuide = false

    var body: some View {
        List {
            if agent.cronJobs.isEmpty {
                ContentUnavailableView(
                    L10n.CronJobs.noCronJobs,
                    systemImage: "clock.badge",
                    description: Text(L10n.CronJobs.noCronJobsDescription)
                )
            } else {
                ForEach(sortedJobs, id: \.id) { job in
                    NavigationLink {
                        CronJobDetailView(job: job)
                    } label: {
                        CronJobRowView(job: job)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteCronJob(job)
                        } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                        }
                        Button {
                            job.isEnabled.toggle()
                            job.updatedAt = Date()
                            if job.isEnabled {
                                job.nextRunAt = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression)
                            }
                            try? modelContext.save()
                        } label: {
                            Label(
                                job.isEnabled ? L10n.Common.disable : L10n.Common.enable,
                                systemImage: job.isEnabled ? "pause" : "play"
                            )
                        }
                        .tint(job.isEnabled ? .orange : .green)
                    }
                    .contextMenu {
                        Button {
                            job.isEnabled.toggle()
                            job.updatedAt = Date()
                            if job.isEnabled {
                                job.nextRunAt = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression)
                            }
                            try? modelContext.save()
                        } label: {
                            Label(
                                job.isEnabled ? L10n.Common.disable : L10n.Common.enable,
                                systemImage: job.isEnabled ? "pause.circle" : "play.circle"
                            )
                        }
                        Button(role: .destructive) {
                            deleteCronJob(job)
                        } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                        }
                    }
                }

                Section {
                    Button {
                        showShortcutsGuide = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.CronJobs.shortcutsTrigger)
                                    .font(.subheadline)
                                Text(L10n.CronJobs.shortcutsDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "shortcuts")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.CronJobs.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            CronJobEditView(agent: agent)
        }
        .sheet(isPresented: $showShortcutsGuide) {
            ShortcutsGuideView(cronJob: nil)
        }
    }

    /// Pre-remove the job from the relationship before modelContext
    /// deletion so the ForEach batch update (row removal) is applied
    /// before SwiftData observation fires from save().
    private func deleteCronJob(_ job: CronJob) {
        agent.cronJobs.removeAll { $0.id == job.id }
        modelContext.delete(job)
        try? modelContext.save()
    }

    private var sortedJobs: [CronJob] {
        agent.cronJobs.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
    }
}

// MARK: - Row

struct CronJobRowView: View {
    let job: CronJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(job.isEnabled ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(job.name)
                    .font(.headline)
                Spacer()
                Text(job.cronExpression)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }

            Text(CronParser.describe(job.cronExpression))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                if let next = job.nextRunAt, job.isEnabled {
                    Label(next, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                Label(L10n.CronJobs.runsCount(job.runCount), systemImage: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(job.jobHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

private extension Label where Title == Text, Icon == Image {
    init(_ date: Date, style: Text.DateStyle) {
        self.init {
            Text(L10n.CronJobs.nextPrefix) + Text(date, style: style)
        } icon: {
            Image(systemName: "clock")
        }
    }
}

// MARK: - Detail

struct CronJobDetailView: View {
    @Bindable var job: CronJob
    @Environment(\.modelContext) private var modelContext
    @State private var showShortcutsGuide = false

    private var triggerURL: String {
        "iclaw://cron/trigger/\(job.id.uuidString)"
    }

    var body: some View {
        Form {
            Section(L10n.CronJobs.jobInfo) {
                LabeledContent(L10n.Common.name, value: job.name)
                LabeledContent(L10n.CronJobs.schedule, value: job.cronExpression)
                LabeledContent(L10n.CronJobs.description, value: CronParser.describe(job.cronExpression))
                Toggle(L10n.CronJobs.enabled, isOn: $job.isEnabled)
                    .onChange(of: job.isEnabled) { _, enabled in
                        if enabled {
                            job.nextRunAt = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression)
                        }
                        job.updatedAt = Date()
                        try? modelContext.save()
                    }
            }

            Section(L10n.CronJobs.jobHint) {
                Text(job.jobHint)
                    .font(.body)
            }

            Section(L10n.CronJobs.statistics) {
                LabeledContent(L10n.CronJobs.totalRuns, value: "\(job.runCount)")
                if let last = job.lastRunAt {
                    LabeledContent(L10n.CronJobs.lastRun) {
                        Text(last, style: .relative) + Text(L10n.CronJobs.ago)
                    }
                }
                if let next = job.nextRunAt, job.isEnabled {
                    LabeledContent(L10n.CronJobs.nextRun) {
                        Text(next, style: .relative)
                    }
                }
                LabeledContent(L10n.CronJobs.created) {
                    Text(job.createdAt, style: .date)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.CronJobs.triggerURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(triggerURL)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.blue)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = triggerURL
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    showShortcutsGuide = true
                } label: {
                    Label(L10n.CronJobs.viewShortcutsGuide, systemImage: "shortcuts")
                }
            } header: {
                Text(L10n.CronJobs.shortcutsIntegration)
            } footer: {
                Text(L10n.CronJobs.shortcutsIntegrationFooter)
            }

            if let sessionId = job.lastSessionId {
                Section(L10n.CronJobs.lastSession) {
                    Text("Session ID: \(sessionId.uuidString)")
                        .font(.caption)
                        .fontDesign(.monospaced)
                }
            }
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShortcutsGuide) {
            ShortcutsGuideView(cronJob: job)
        }
    }
}

// MARK: - Create / Edit

struct CronJobEditView: View {
    let agent: Agent
    var existingJob: CronJob?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cronExpression = "0 9 * * *"
    @State private var jobHint = ""
    @State private var isEnabled = true
    @State private var validationError: String?
    @State private var showShortcutsGuide = false
    @State private var savedJob: CronJob?

    private var isEditing: Bool { existingJob != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.CronJobs.basic) {
                    TextField(L10n.CronJobs.jobName, text: $name)
                    Toggle(L10n.CronJobs.enabled, isOn: $isEnabled)
                }

                Section {
                    TextField(L10n.CronJobs.cronExpression, text: $cronExpression)
                        .fontDesign(.monospaced)
                        .autocapitalization(.none)
                        .onChange(of: cronExpression) { _, _ in validate() }

                    if let error = validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(CronParser.describe(cronExpression))
                            .font(.caption)
                            .foregroundStyle(.green)

                        if let next = try? CronParser.nextFireDate(after: Date(), for: cronExpression) {
                            HStack {
                                Text(L10n.CronJobs.nextFire)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(next, style: .date)
                                    .font(.caption)
                                Text(next, style: .time)
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text(L10n.CronJobs.schedule)
                } footer: {
                    Text(L10n.CronJobs.cronFormat)
                }

                Section(L10n.CronJobs.quickPresets) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            presetButton(L10n.CronJobs.everyHour, "0 * * * *")
                            presetButton(L10n.CronJobs.daily9am, "0 9 * * *")
                            presetButton(L10n.CronJobs.weekdays9am, "0 9 * * 1-5")
                            presetButton(L10n.CronJobs.weeklyMon, "0 9 * * 1")
                            presetButton(L10n.CronJobs.every30min, "*/30 * * * *")
                            presetButton(L10n.CronJobs.monthly1st, "0 0 1 * *")
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    TextEditor(text: $jobHint)
                        .frame(minHeight: 120)
                } header: {
                    Text(L10n.CronJobs.jobHint)
                } footer: {
                    Text(L10n.CronJobs.jobHintFooter)
                }
            }
            .navigationTitle(isEditing ? L10n.CronJobs.editJob : L10n.CronJobs.newCronJob)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        save()
                        if !isEditing {
                            showShortcutsGuide = true
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(name.isEmpty || jobHint.isEmpty || validationError != nil)
                }
            }
            .onAppear {
                if let job = existingJob {
                    name = job.name
                    cronExpression = job.cronExpression
                    jobHint = job.jobHint
                    isEnabled = job.isEnabled
                }
                validate()
            }
            .sheet(isPresented: $showShortcutsGuide, onDismiss: { dismiss() }) {
                ShortcutsGuideView(cronJob: savedJob)
            }
        }
    }

    private func presetButton(_ label: String, _ expr: String) -> some View {
        Button {
            cronExpression = expr
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(cronExpression == expr ? Color.accentColor : Color(.systemGray5))
                )
                .foregroundStyle(cronExpression == expr ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private func validate() {
        validationError = CronParser.validate(cronExpression)
    }

    private func save() {
        if let job = existingJob {
            job.name = name
            job.cronExpression = cronExpression
            job.jobHint = jobHint
            job.isEnabled = isEnabled
            job.nextRunAt = try? CronParser.nextFireDate(after: Date(), for: cronExpression)
            job.updatedAt = Date()
            savedJob = job
        } else {
            let job = CronJob(
                name: name,
                cronExpression: cronExpression,
                jobHint: jobHint,
                isEnabled: isEnabled
            )
            job.nextRunAt = try? CronParser.nextFireDate(after: Date(), for: cronExpression)
            modelContext.insert(job)
            agent.cronJobs.append(job)
            savedJob = job
        }
        try? modelContext.save()
    }
}
