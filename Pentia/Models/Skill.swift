import Foundation
import SwiftData

// MARK: - Skill Script

struct SkillScript: Codable, Hashable {
    let name: String
    let language: String
    let code: String
    let description: String?

    init(name: String, language: String = "javascript", code: String, description: String? = nil) {
        self.name = name
        self.language = language
        self.code = code
        self.description = description
    }
}

// MARK: - Skill Custom Tool

struct SkillToolDefinition: Codable, Hashable {
    let name: String
    let description: String
    let parameters: [SkillToolParam]
    let implementation: String

    init(name: String, description: String, parameters: [SkillToolParam] = [], implementation: String) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.implementation = implementation
    }
}

struct SkillToolParam: Codable, Hashable {
    let name: String
    let type: String
    let description: String
    let required: Bool
    let enumValues: [String]?

    init(name: String, type: String = "string", description: String, required: Bool = true, enumValues: [String]? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.enumValues = enumValues
    }
}

// MARK: - Skill Config Schema

struct SkillConfigField: Codable, Hashable {
    let key: String
    let label: String
    let type: String
    let required: Bool
    let defaultValue: String?

    init(key: String, label: String, type: String = "string", required: Bool = false, defaultValue: String? = nil) {
        self.key = key
        self.label = label
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
    }
}

// MARK: - Skill Model

@Model
final class Skill {
    var id: UUID
    var name: String
    var nameLowercase: String = ""
    /// Localized display name for built-in skills. Empty for custom skills,
    /// which fall back to `name`. Never used as an identifier — `name` remains
    /// the stable English key for template matching, tool-name generation, and
    /// CodeSnippet registration.
    var displayName: String = ""
    var summary: String
    var content: String
    var tagsRaw: String
    var author: String
    var version: String
    var isBuiltIn: Bool
    @Relationship(deleteRule: .cascade, inverse: \InstalledSkill.skill)
    var installations: [InstalledSkill]
    var createdAt: Date
    var updatedAt: Date

    // Executable skill data (JSON-encoded)
    var scriptsRaw: String = "[]"
    var toolsRaw: String = "[]"
    var configSchemaRaw: String = "[]"

    var tags: [String] {
        get { tagsRaw.isEmpty ? [] : tagsRaw.components(separatedBy: ",") }
        set { tagsRaw = newValue.joined(separator: ",") }
    }

    var scripts: [SkillScript] {
        get { (try? JSONDecoder().decode([SkillScript].self, from: Data(scriptsRaw.utf8))) ?? [] }
        set { scriptsRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    var customTools: [SkillToolDefinition] {
        get { (try? JSONDecoder().decode([SkillToolDefinition].self, from: Data(toolsRaw.utf8))) ?? [] }
        set { toolsRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    var configSchema: [SkillConfigField] {
        get { (try? JSONDecoder().decode([SkillConfigField].self, from: Data(configSchemaRaw.utf8))) ?? [] }
        set { configSchemaRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]" }
    }

    var installCount: Int { installations.count }

    /// UI-facing name. Prefers `displayName` when populated (built-in skills),
    /// otherwise falls back to `name` (custom skills, and built-ins before their
    /// first localization pass).
    var effectiveDisplayName: String {
        displayName.isEmpty ? name : displayName
    }

    init(
        name: String,
        summary: String,
        content: String,
        tags: [String] = [],
        author: String = "user",
        version: String = "1.0",
        isBuiltIn: Bool = false,
        scripts: [SkillScript] = [],
        customTools: [SkillToolDefinition] = [],
        configSchema: [SkillConfigField] = []
    ) {
        self.id = UUID()
        self.name = name
        self.nameLowercase = name.lowercased()
        self.summary = summary
        self.content = content
        self.tagsRaw = tags.joined(separator: ",")
        self.author = author
        self.version = version
        self.isBuiltIn = isBuiltIn
        self.installations = []
        self.createdAt = Date()
        self.updatedAt = Date()
        self.scriptsRaw = (try? String(data: JSONEncoder().encode(scripts), encoding: .utf8)) ?? "[]"
        self.toolsRaw = (try? String(data: JSONEncoder().encode(customTools), encoding: .utf8)) ?? "[]"
        self.configSchemaRaw = (try? String(data: JSONEncoder().encode(configSchema), encoding: .utf8)) ?? "[]"
    }
}

// MARK: - LLM Tool Conversion

extension SkillToolDefinition {
    /// Convert this skill tool definition to an LLM-compatible tool definition.
    func toLLMToolDefinition(skillName: String) -> LLMToolDefinition {
        let toolName = PromptBuilder.skillToolName(skillName: skillName, toolName: name)
        let properties = parameters.reduce(into: [String: JSONSchemaProperty]()) { dict, param in
            dict[param.name] = JSONSchemaProperty(
                type: param.type,
                description: param.description,
                enumValues: param.enumValues
            )
        }
        let required = parameters.filter { $0.required }.map { $0.name }
        return ToolDefinitionBuilder.build(
            name: toolName,
            description: "[\(skillName)] \(description)",
            properties: properties,
            required: required
        )
    }
}
