import SwiftUI

/// Displays tool calls from the assistant as styled, expandable cards.
struct ToolCallCardView: View {
    let toolCalls: [LLMToolCall]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(toolCalls, id: \.id) { call in
                SingleToolCallCard(call: call)
            }
        }
    }
}

private struct SingleToolCallCard: View {
    let call: LLMToolCall
    @State private var isExpanded = false

    private var toolMeta: ToolMeta {
        ToolMeta.resolve(call.function.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolMeta.icon)
                        .font(.caption)
                        .foregroundStyle(toolMeta.color)
                        .frame(width: 20, height: 20)
                        .background(toolMeta.color.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    if let scope = toolMeta.scope {
                        Text(scope)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(toolMeta.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(toolMeta.color.opacity(0.12))
                            .clipShape(Capsule())
                            .fixedSize()
                    }

                    Text(toolMeta.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let summary = parseSummary(call) {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 10)
                Text(formatArguments(call.function.arguments))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(toolMeta.color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(toolMeta.color.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func parseSummary(_ call: LLMToolCall) -> String? {
        guard let data = call.function.arguments.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        switch call.function.name {
        case "execute_javascript":
            let mode = dict["mode"] as? String ?? "script"
            return "(\(mode))"
        case "read_config", "write_config":
            return dict["key"] as? String
        case "schedule_cron":
            return dict["name"] as? String
        case "create_sub_agent":
            let name = dict["name"] as? String ?? ""
            let type = dict["type"] as? String ?? "temp"
            return name.isEmpty ? nil : "\(name) [\(type)]"
        case "message_sub_agent", "collect_sub_agent_output", "stop_sub_agent", "delete_sub_agent":
            if let id = dict["agent_id"] as? String {
                return String(id.prefix(8)) + "..."
            }
            return nil
        case "file_list":
            return nil
        case "file_read", "file_write", "file_delete", "file_info", "attach_media":
            return dict["name"] as? String
        case "save_code", "run_snippet", "delete_code":
            return dict["name"] as? String
        case "install_skill", "uninstall_skill":
            return dict["name"] as? String
        case "browser_navigate":
            if let url = dict["url"] as? String {
                return url.count > 40 ? String(url.prefix(40)) + "..." : url
            }
            return dict["action"] as? String
        case "browser_click", "browser_input", "browser_extract", "browser_wait", "browser_select":
            return dict["selector"] as? String
        case "browser_scroll":
            return dict["direction"] as? String ?? "down"
        case "calendar_create_event":
            return dict["title"] as? String
        case "calendar_search_events":
            return dict["keyword"] as? String ?? dict["start_date"] as? String
        case "calendar_update_event", "calendar_delete_event":
            return dict["event_id"] as? String
        case "reminder_create":
            return dict["title"] as? String
        case "reminder_complete", "reminder_delete":
            return dict["reminder_id"] as? String
        case "reminder_list":
            return dict["list_name"] as? String
        case "contacts_search":
            return dict["query"] as? String
        case "contacts_get_detail":
            return dict["contact_id"] as? String
        case "clipboard_write":
            if let text = dict["text"] as? String {
                return text.count > 20 ? String(text.prefix(20)) + "..." : text
            }
            return nil
        case "notification_schedule":
            return dict["title"] as? String
        case "notification_cancel":
            return dict["id"] as? String
        case "location_geocode":
            return dict["address"] as? String
        case "location_reverse_geocode":
            if let lat = dict["latitude"] as? Double, let lon = dict["longitude"] as? Double {
                return String(format: "%.4f, %.4f", lat, lon)
            }
            return nil
        case "map_search_places":
            return dict["query"] as? String
        case "map_get_directions":
            return dict["to_address"] as? String
        case "health_write_dietary_energy":
            if let kcal = dict["kcal"] as? Double { return String(format: "%.0f kcal", kcal) }
            return nil
        case "health_write_dietary_water":
            if let ml = dict["ml"] as? Double { return String(format: "%.0f ml", ml) }
            return nil
        case "health_write_dietary_carbohydrates", "health_write_dietary_protein", "health_write_dietary_fat":
            if let grams = dict["grams"] as? Double { return String(format: "%.1f g", grams) }
            return nil
        case "health_write_body_mass":
            if let value = dict["value"] as? Double {
                let unit = (dict["unit"] as? String) ?? "kg"
                return String(format: "%.2f %@", value, unit)
            }
            return nil
        case "health_write_blood_pressure":
            if let sys = dict["systolic"] as? Double, let dia = dict["diastolic"] as? Double {
                return "\(Int(sys))/\(Int(dia)) mmHg"
            }
            return nil
        case "health_write_body_fat":
            if let pct = dict["percentage"] as? Double { return String(format: "%.1f%%", pct) }
            return nil
        case "health_write_height":
            if let v = dict["value"] as? Double {
                let unit = (dict["unit"] as? String) ?? "cm"
                return String(format: "%.1f %@", v, unit)
            }
            return nil
        case "health_write_blood_glucose":
            if let v = dict["value"] as? Double {
                let unit = (dict["unit"] as? String) ?? "mmol/L"
                return String(format: "%.2f %@", v, unit)
            }
            return nil
        case "health_write_blood_oxygen":
            if let pct = dict["percentage"] as? Double { return String(format: "%.1f%%", pct) }
            return nil
        case "health_write_body_temperature":
            if let v = dict["value"] as? Double {
                let unit = (dict["unit"] as? String)?.lowercased() == "f" ? "°F" : "°C"
                return String(format: "%.1f %@", v, unit)
            }
            return nil
        case "health_write_heart_rate":
            if let bpm = dict["bpm"] as? Double { return "\(Int(bpm)) bpm" }
            return nil
        case "health_write_workout":
            return dict["activity_type"] as? String
        case let name where name.hasPrefix("health_read_"):
            return dict["start_date"] as? String
        default:
            return nil
        }
    }

    private func formatArguments(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return str
    }
}

/// Tool result card for displaying tool execution results in the chat.
struct ToolResultCardView: View {
    let message: Message
    @State private var isExpanded = false

    private var toolName: String {
        message.name ?? "tool"
    }

    private var content: String {
        message.content ?? ""
    }

    private var toolMeta: ToolMeta {
        ToolMeta.resolve(toolName)
    }

    private var isError: Bool {
        content.hasPrefix("[Error]") || content.hasPrefix("[stderr]")
    }

    private var isCodeExecution: Bool {
        toolName == "execute_javascript" || toolName == "run_snippet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                cardHeader
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.horizontal, 10)

                if isCodeExecution {
                    codeResultView
                } else {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isError ? .red : .primary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isError ? Color.red.opacity(0.04) : Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isError ? Color.red.opacity(0.2) : Color(.systemGray4).opacity(0.3), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var cardHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)

                Image(systemName: toolMeta.icon)
                    .font(.caption)
                    .foregroundStyle(toolMeta.color)

                if let scope = toolMeta.scope {
                    Text(scope)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(toolMeta.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(toolMeta.color.opacity(0.12))
                        .clipShape(Capsule())
                        .fixedSize()
                }

                Text(toolMeta.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }

            if !isExpanded && !content.isEmpty {
                Text(content.prefix(120).replacingOccurrences(of: "\n", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var codeResultView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let parts = parseCodeOutput(content)

            if let stdout = parts.stdout, !stdout.isEmpty {
                HStack {
                    Text(L10n.ToolResult.stdout)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    copyButton(stdout)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

                Text(stdout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let stderr = parts.stderr, !stderr.isEmpty {
                Divider().padding(.horizontal, 10)
                HStack {
                    Text(L10n.ToolResult.stderr)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

                Text(stderr)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if let repl = parts.repl, !repl.isEmpty {
                Divider().padding(.horizontal, 10)
                HStack(spacing: 4) {
                    Text("→")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                    Text(repl)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.blue)
                        .textSelection(.enabled)
                    Spacer()
                    copyButton(repl)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            if parts.stdout == nil && parts.stderr == nil && parts.repl == nil {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func parseCodeOutput(_ output: String) -> (stdout: String?, stderr: String?, repl: String?) {
        var stdout: String?
        var stderr: String?
        var repl: String?
        var currentSection: [String] = []

        let lines = output.components(separatedBy: "\n")
        var mode = "stdout"

        for line in lines {
            if line.hasPrefix("[stderr] ") {
                if !currentSection.isEmpty && mode == "stdout" {
                    stdout = currentSection.joined(separator: "\n")
                    currentSection = []
                }
                mode = "stderr"
                currentSection.append(String(line.dropFirst(9)))
            } else if mode == "stderr" && !line.hasPrefix("[stderr]") {
                stderr = currentSection.joined(separator: "\n")
                currentSection = []
                mode = "repl"
                repl = line
            } else {
                currentSection.append(line)
            }
        }

        if !currentSection.isEmpty {
            switch mode {
            case "stdout":
                let joined = currentSection.joined(separator: "\n")
                if joined == "(No output)" {
                    // No output
                } else {
                    stdout = joined
                }
            case "stderr":
                stderr = currentSection.joined(separator: "\n")
            default:
                repl = currentSection.joined(separator: "\n")
            }
        }

        return (stdout, stderr, repl)
    }
}

// MARK: - Tool metadata

struct ToolMeta {
    let displayName: String
    let icon: String
    let color: Color
    var scope: String? = nil

    static func resolve(_ toolName: String) -> ToolMeta {
        switch toolName {
        case "execute_javascript":
            return ToolMeta(displayName: L10n.ToolCard.javascript, icon: "terminal.fill", color: .yellow)
        case "read_config":
            return ToolMeta(displayName: L10n.ToolCard.readConfig, icon: "doc.text", color: .purple)
        case "write_config":
            return ToolMeta(displayName: L10n.ToolCard.writeConfig, icon: "square.and.pencil", color: .purple)
        case "save_code":
            return ToolMeta(displayName: L10n.ToolCard.saveCode, icon: "square.and.arrow.down", color: .blue)
        case "load_code":
            return ToolMeta(displayName: L10n.ToolCard.loadCode, icon: "square.and.arrow.up", color: .blue)
        case "list_code":
            return ToolMeta(displayName: L10n.ToolCard.listCode, icon: "list.bullet", color: .blue)
        case "run_snippet":
            return ToolMeta(displayName: L10n.ToolCard.runSnippet, icon: "play.fill", color: .blue)
        case "delete_code":
            return ToolMeta(displayName: L10n.ToolCard.deleteCode, icon: "trash", color: .blue)
        case "create_sub_agent":
            return ToolMeta(displayName: L10n.ToolCard.createAgent, icon: "person.badge.plus", color: .orange)
        case "message_sub_agent":
            return ToolMeta(displayName: L10n.ToolCard.messageAgent, icon: "bubble.left.and.bubble.right", color: .orange)
        case "collect_sub_agent_output":
            return ToolMeta(displayName: L10n.ToolCard.collectOutput, icon: "tray.and.arrow.down", color: .orange)
        case "list_sub_agents":
            return ToolMeta(displayName: L10n.ToolCard.listAgents, icon: "person.3", color: .orange)
        case "stop_sub_agent":
            return ToolMeta(displayName: L10n.ToolCard.stopAgent, icon: "stop.circle", color: .red)
        case "delete_sub_agent":
            return ToolMeta(displayName: L10n.ToolCard.deleteAgent, icon: "person.badge.minus", color: .red)
        case "schedule_cron":
            return ToolMeta(displayName: L10n.ToolCard.scheduleJob, icon: "clock.badge.checkmark", color: .green)
        case "unschedule_cron":
            return ToolMeta(displayName: L10n.ToolCard.removeJob, icon: "clock.badge.xmark", color: .red)
        case "list_cron":
            return ToolMeta(displayName: L10n.ToolCard.listJobs, icon: "clock", color: .green)
        case "create_skill":
            return ToolMeta(displayName: L10n.ToolCard.createSkill, icon: "sparkles", color: .indigo)
        case "delete_skill":
            return ToolMeta(displayName: L10n.ToolCard.deleteSkill, icon: "sparkles", color: .indigo)
        case "install_skill":
            return ToolMeta(displayName: L10n.ToolCard.installSkill, icon: "sparkles", color: .indigo)
        case "uninstall_skill":
            return ToolMeta(displayName: L10n.ToolCard.uninstallSkill, icon: "sparkles", color: .indigo)
        case "list_skills":
            return ToolMeta(displayName: L10n.ToolCard.listSkills, icon: "sparkles", color: .indigo)
        case "read_skill":
            return ToolMeta(displayName: L10n.ToolCard.readSkill, icon: "sparkles", color: .indigo)
        case "set_model":
            return ToolMeta(displayName: L10n.ToolCard.setModel, icon: "cpu", color: .teal)
        case "get_model":
            return ToolMeta(displayName: L10n.ToolCard.getModel, icon: "cpu", color: .teal)
        case "list_models":
            return ToolMeta(displayName: L10n.ToolCard.listModels, icon: "list.bullet.rectangle", color: .teal)
        case "file_list":
            return ToolMeta(displayName: L10n.ToolCard.fileList, icon: "folder", color: .cyan)
        case "file_read":
            return ToolMeta(displayName: L10n.ToolCard.fileRead, icon: "doc.text", color: .cyan)
        case "file_write":
            return ToolMeta(displayName: L10n.ToolCard.fileWrite, icon: "doc.badge.plus", color: .cyan)
        case "file_delete":
            return ToolMeta(displayName: L10n.ToolCard.fileDelete, icon: "trash", color: .red)
        case "file_info":
            return ToolMeta(displayName: L10n.ToolCard.fileInfo, icon: "doc.badge.gearshape", color: .cyan)
        case "attach_media":
            return ToolMeta(displayName: L10n.ToolCard.attachMedia, icon: "photo.badge.plus", color: .cyan)
        case "browser_navigate":
            return ToolMeta(displayName: L10n.ToolCard.browse, icon: "globe", color: .cyan)
        case "browser_get_page_info":
            return ToolMeta(displayName: L10n.ToolCard.pageInfo, icon: "doc.text.magnifyingglass", color: .cyan)
        case "browser_click":
            return ToolMeta(displayName: L10n.ToolCard.click, icon: "cursorarrow.click", color: .cyan)
        case "browser_input":
            return ToolMeta(displayName: L10n.ToolCard.input, icon: "keyboard", color: .cyan)
        case "browser_select":
            return ToolMeta(displayName: L10n.ToolCard.select, icon: "checklist", color: .cyan)
        case "browser_extract":
            return ToolMeta(displayName: L10n.ToolCard.extract, icon: "text.magnifyingglass", color: .cyan)
        case "browser_execute_js":
            return ToolMeta(displayName: L10n.ToolCard.browserJS, icon: "chevron.left.forwardslash.chevron.right", color: .cyan)
        case "browser_wait":
            return ToolMeta(displayName: L10n.ToolCard.waitElement, icon: "clock.arrow.circlepath", color: .cyan)
        case "browser_scroll":
            return ToolMeta(displayName: L10n.ToolCard.scroll, icon: "scroll", color: .cyan)
        case "calendar_list_calendars":
            return ToolMeta(displayName: L10n.ToolCard.calendarListCalendars, icon: "calendar", color: .mint)
        case "calendar_create_event":
            return ToolMeta(displayName: L10n.ToolCard.calendarCreateEvent, icon: "calendar.badge.plus", color: .mint)
        case "calendar_search_events":
            return ToolMeta(displayName: L10n.ToolCard.calendarSearchEvents, icon: "calendar.badge.clock", color: .mint)
        case "calendar_update_event":
            return ToolMeta(displayName: L10n.ToolCard.calendarUpdateEvent, icon: "calendar.badge.exclamationmark", color: .mint)
        case "calendar_delete_event":
            return ToolMeta(displayName: L10n.ToolCard.calendarDeleteEvent, icon: "calendar.badge.minus", color: .red)
        case "reminder_lists":
            return ToolMeta(displayName: L10n.ToolCard.reminderLists, icon: "list.bullet.clipboard", color: .green)
        case "reminder_list":
            return ToolMeta(displayName: L10n.ToolCard.reminderList, icon: "checklist", color: .green)
        case "reminder_create":
            return ToolMeta(displayName: L10n.ToolCard.reminderCreate, icon: "checklist.checked", color: .green)
        case "reminder_complete":
            return ToolMeta(displayName: L10n.ToolCard.reminderComplete, icon: "checkmark.circle", color: .green)
        case "reminder_delete":
            return ToolMeta(displayName: L10n.ToolCard.reminderDelete, icon: "trash.circle", color: .red)
        case "contacts_search":
            return ToolMeta(displayName: L10n.ToolCard.contactsSearch, icon: "person.crop.circle.badge.magnifyingglass", color: .indigo)
        case "contacts_get_detail":
            return ToolMeta(displayName: L10n.ToolCard.contactsGetDetail, icon: "person.text.rectangle", color: .indigo)
        case "clipboard_read":
            return ToolMeta(displayName: L10n.ToolCard.clipboardRead, icon: "doc.on.clipboard", color: .brown)
        case "clipboard_write":
            return ToolMeta(displayName: L10n.ToolCard.clipboardWrite, icon: "clipboard", color: .brown)
        case "notification_schedule":
            return ToolMeta(displayName: L10n.ToolCard.notificationSchedule, icon: "bell.badge", color: .orange)
        case "notification_cancel":
            return ToolMeta(displayName: L10n.ToolCard.notificationCancel, icon: "bell.slash", color: .red)
        case "notification_list":
            return ToolMeta(displayName: L10n.ToolCard.notificationList, icon: "bell", color: .orange)
        case "location_get_current":
            return ToolMeta(displayName: L10n.ToolCard.locationGetCurrent, icon: "location.fill", color: .teal)
        case "location_geocode":
            return ToolMeta(displayName: L10n.ToolCard.locationGeocode, icon: "mappin.and.ellipse", color: .teal)
        case "location_reverse_geocode":
            return ToolMeta(displayName: L10n.ToolCard.locationReverseGeocode, icon: "map", color: .teal)
        case "map_search_places":
            return ToolMeta(displayName: L10n.ToolCard.mapSearchPlaces, icon: "magnifyingglass.circle", color: .blue)
        case "map_get_directions":
            return ToolMeta(displayName: L10n.ToolCard.mapGetDirections, icon: "point.topleft.down.curvedto.point.bottomright.up", color: .blue)
        case "health_read_steps":
            return ToolMeta(displayName: L10n.ToolCard.healthReadSteps, icon: "figure.walk", color: .pink)
        case "health_read_heart_rate":
            return ToolMeta(displayName: L10n.ToolCard.healthReadHeartRate, icon: "heart.text.square", color: .pink)
        case "health_read_sleep":
            return ToolMeta(displayName: L10n.ToolCard.healthReadSleep, icon: "bed.double", color: .pink)
        case "health_read_body_mass":
            return ToolMeta(displayName: L10n.ToolCard.healthReadBodyMass, icon: "scalemass", color: .pink)
        case "health_read_blood_pressure":
            return ToolMeta(displayName: L10n.ToolCard.healthReadBloodPressure, icon: "heart.circle", color: .pink)
        case "health_read_blood_glucose":
            return ToolMeta(displayName: L10n.ToolCard.healthReadBloodGlucose, icon: "drop.triangle", color: .pink)
        case "health_read_blood_oxygen":
            return ToolMeta(displayName: L10n.ToolCard.healthReadBloodOxygen, icon: "lungs", color: .pink)
        case "health_read_body_temperature":
            return ToolMeta(displayName: L10n.ToolCard.healthReadBodyTemperature, icon: "thermometer.medium", color: .pink)
        case "health_write_dietary_energy":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteDietaryEnergy, icon: "fork.knife.circle", color: .red)
        case "health_write_body_mass":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteBodyMass, icon: "square.and.pencil.circle", color: .red)
        case "health_write_dietary_water":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteDietaryWater, icon: "drop.circle", color: .blue)
        case "health_write_dietary_carbohydrates":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteDietaryCarbohydrates, icon: "leaf.circle", color: .orange)
        case "health_write_dietary_protein":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteDietaryProtein, icon: "bolt.heart", color: .orange)
        case "health_write_dietary_fat":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteDietaryFat, icon: "flame.circle", color: .orange)
        case "health_write_blood_pressure":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteBloodPressure, icon: "heart.circle.fill", color: .red)
        case "health_write_body_fat":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteBodyFat, icon: "percent", color: .red)
        case "health_write_height":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteHeight, icon: "ruler", color: .red)
        case "health_write_blood_glucose":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteBloodGlucose, icon: "drop.triangle.fill", color: .red)
        case "health_write_blood_oxygen":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteBloodOxygen, icon: "lungs.fill", color: .red)
        case "health_write_body_temperature":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteBodyTemperature, icon: "thermometer.medium", color: .red)
        case "health_write_heart_rate":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteHeartRate, icon: "heart.fill", color: .red)
        case "health_write_workout":
            return ToolMeta(displayName: L10n.ToolCard.healthWriteWorkout, icon: "figure.run.circle", color: .red)
        case "generate_image":
            return ToolMeta(displayName: L10n.ToolCard.generateImage, icon: "photo.artframe", color: .orange)
        case "generate_video":
            return ToolMeta(displayName: L10n.ToolCard.generateVideo, icon: "film", color: .purple)
        // Session RAG
        case "search_sessions":
            return ToolMeta(displayName: L10n.ToolCard.searchSessions, icon: "text.magnifyingglass", color: .purple)
        case "recall_session":
            return ToolMeta(displayName: L10n.ToolCard.recallSession, icon: "bubble.left.and.text.bubble.right.fill", color: .purple)
        default:
            return humanizeUnknown(toolName)
        }
    }

    // MARK: - Humanization for unmapped tool names

    /// Fallback for tool names not covered by the explicit switch above.
    /// Skill-defined custom tools arrive as `skill_<sanitized_skill_name>_<tool>`
    /// (see `PromptBuilder.skillToolName`); we strip the prefix and tag the
    /// card with a "Skill" scope so it visually matches other skill UI.
    /// Any other unknown tool name is returned raw with a wrench icon —
    /// this preserves the documented invariant relied on by
    /// `BackgroundKeepAliveManager.formatSilentStatusBrief` and its tests.
    private static func humanizeUnknown(_ raw: String) -> ToolMeta {
        if raw.hasPrefix("skill_") {
            let body = String(raw.dropFirst("skill_".count))
            let label = humanizeIdentifier(body)
            return ToolMeta(
                displayName: label.isEmpty ? raw : label,
                icon: "sparkles",
                color: .indigo,
                scope: L10n.ToolCard.skillScope
            )
        }
        return ToolMeta(displayName: raw, icon: "wrench", color: .gray)
    }

    /// Splits snake_case / kebab-case / camelCase / PascalCase identifiers
    /// into space-separated Title Case words, preserving common acronyms.
    private static func humanizeIdentifier(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }

        let normalized = raw
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        // Split camelCase / PascalCase by inserting spaces before uppercase
        // letters that follow a lowercase letter, or that precede a lowercase
        // letter inside an uppercase run (so "URLPath" -> "URL Path").
        var spaced = ""
        let chars = Array(normalized)
        for i in chars.indices {
            let ch = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if ch.isUppercase && prev.isLowercase {
                    spaced.append(" ")
                } else if let next, ch.isUppercase && prev.isUppercase && next.isLowercase {
                    spaced.append(" ")
                }
            }
            spaced.append(ch)
        }

        let acronyms: Set<String> = [
            "URL", "URI", "API", "JS", "JSON", "HTML", "CSS", "SQL", "ID",
            "UI", "HTTP", "HTTPS", "IO", "AI", "ML", "SDK", "CLI", "PDF",
            "CSV", "XML", "YAML", "TOML", "OS", "IP", "DNS"
        ]

        let words = spaced
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                let upper = word.uppercased()
                if acronyms.contains(upper) { return upper }
                let first = word.prefix(1).uppercased()
                let rest = word.dropFirst().lowercased()
                return first + rest
            }
        return words.joined(separator: " ")
    }
}
