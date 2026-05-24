import Foundation

// Convenience builders for creating tool definitions
enum ToolDefinitionBuilder {
    static func build(
        name: String,
        description: String,
        properties: [String: JSONSchemaProperty] = [:],
        required: [String] = []
    ) -> LLMToolDefinition {
        LLMToolDefinition(
            function: LLMFunctionDefinition(
                name: name,
                description: description,
                parameters: JSONSchema(
                    type: "object",
                    properties: properties.isEmpty ? nil : properties,
                    required: required.isEmpty ? nil : required
                )
            )
        )
    }

    static func stringParam(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "string", description: description)
    }

    static func enumParam(_ description: String, values: [String]) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "string", description: description, enumValues: values)
    }

    static func intParam(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "integer", description: description)
    }

    static func boolParam(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "boolean", description: description)
    }

    static func numberParam(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "number", description: description)
    }

    static func objectParam(_ description: String) -> JSONSchemaProperty {
        JSONSchemaProperty(type: "object", description: description)
    }
}
