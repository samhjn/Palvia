import XCTest
@testable import iClaw

/// Structural and behavioral tests for the shipped built-in skills.
///
/// All assertions go through `BuiltInSkills.allResolvedTemplates()` — the
/// public surface that consumes the on-disk packages under
/// `Resources/BuiltInSkills/<slug>/`. There is no separate Swift-string
/// template path anymore; if a built-in's package fails to parse, this test
/// suite catches it via `testExpectedBuiltInSkillsRegistered`.
final class BuiltInSkillsTests: XCTestCase {

    // MARK: - Registry

    private var allTemplates: [BuiltInSkills.ResolvedTemplate] {
        BuiltInSkills.allResolvedTemplates()
    }

    func testBuiltInSkillsNotEmpty() {
        XCTAssertFalse(allTemplates.isEmpty)
    }

    func testAllSkillsHaveUniqueNames() {
        let names = allTemplates.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Built-in skill names must be unique")
    }

    func testAllSkillsHaveNonEmptyContent() {
        for template in allTemplates {
            XCTAssertFalse(template.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Skill '\(template.name)' must have non-empty content")
        }
    }

    func testAllSkillsHaveNonEmptySummary() {
        for template in allTemplates {
            XCTAssertFalse(template.summary.isEmpty,
                           "Skill '\(template.name)' must have a summary")
        }
    }

    func testAllSkillsHaveNonEmptyDisplayName() {
        for template in allTemplates {
            XCTAssertFalse(template.displayName.isEmpty,
                           "Skill '\(template.name)' must have a display name")
        }
    }

    func testAllSkillsHaveTags() {
        for template in allTemplates {
            XCTAssertFalse(template.tags.isEmpty,
                           "Skill '\(template.name)' must have at least one tag")
        }
    }

    /// Built-in templates must ship real capabilities (scripts or custom tools).
    /// Pure-prose templates like the earlier "Code Review" / "Daily Planner" /
    /// "Creative Writer" were removed because the model can improvise that
    /// guidance on its own, and carrying them as built-ins only inflated the
    /// library UI.
    func testAllSkillsShipExecutableCapabilities() {
        for template in allTemplates {
            let hasCapability = !template.scripts.isEmpty || !template.customTools.isEmpty
            XCTAssertTrue(hasCapability,
                          "Built-in skill '\(template.name)' must ship scripts or custom tools, not just prose")
        }
    }

    func testExpectedBuiltInSkillsRegistered() {
        let names = Set(allTemplates.map(\.name))
        XCTAssertEqual(names, Set(["Deep Research", "File Ops", "Health Plus", "Skill Builder"]),
                       "Unexpected set of built-in skills; update this test intentionally when the list changes")
    }

    func testRemovedSkillsNoLongerRegistered() {
        let names = Set(allTemplates.map(\.name))
        XCTAssertFalse(names.contains("Code Review"))
        XCTAssertFalse(names.contains("Daily Planner"))
        XCTAssertFalse(names.contains("Creative Writer"))
    }

    func testResolvedTemplatesHaveNonEmptyToolDescriptions() {
        for template in allTemplates {
            for tool in template.customTools {
                XCTAssertFalse(tool.description.isEmpty,
                               "Tool '\(tool.name)' on skill '\(template.name)' must have a description")
            }
        }
    }

    func testShippedSlugsMatchRegistrations() {
        // Every slug listed in BuiltInSkills.shippedSlugs must produce a
        // resolvable template, and there must be no extras.
        let expectedCount = BuiltInSkills.shippedSlugs.count
        XCTAssertEqual(allTemplates.count, expectedCount,
                       "shippedSlugs lists \(expectedCount) skills but allResolvedTemplates returned \(allTemplates.count) — a package is missing or failed to parse")
    }

    // MARK: - Deep Research

    private var deepResearch: BuiltInSkills.ResolvedTemplate {
        allTemplates.first(where: { $0.name == "Deep Research" })!
    }

    func testDeepResearchSkillExists() {
        XCTAssertNotNil(allTemplates.first(where: { $0.name == "Deep Research" }))
    }

    func testDeepResearchHasTwoScripts() {
        XCTAssertEqual(deepResearch.scripts.count, 2)
    }

    func testDeepResearchHasOneCustomTool() {
        XCTAssertEqual(deepResearch.customTools.count, 1)
    }

    func testDeepResearchTags() {
        let tags = deepResearch.tags
        XCTAssertTrue(tags.contains("research"))
        XCTAssertTrue(tags.contains("analysis"))
    }

    func testDeepResearchContentMentionsBrowserTools() {
        let content = deepResearch.content
        XCTAssertTrue(content.contains("browser_navigate"),
                      "Methodology should guide using browser_navigate")
        XCTAssertTrue(content.contains("browser_get_page_info"),
                      "Methodology should guide using browser_get_page_info")
        XCTAssertTrue(content.contains("browser_extract"),
                      "Methodology should guide using browser_extract")
    }

    func testDeepResearchContentHasToolPreferenceOrder() {
        let content = deepResearch.content
        // Tool identifiers are kept in English across translations; the body
        // surrounding them may differ, but this ordering check uses the
        // identifiers themselves so it's locale-agnostic.
        guard let browserRange = content.range(of: "browser_navigate"),
              let fetchRange = content.range(of: "fetch_and_extract") else {
            XCTFail("Content must mention both browser_navigate and fetch_and_extract")
            return
        }
        XCTAssertTrue(browserRange.lowerBound < fetchRange.lowerBound,
                      "Browser tools should be listed before fetch_and_extract in preference order")
    }

    // MARK: - Deep Research: extract_links Script

    private var extractLinksScript: SkillScript {
        deepResearch.scripts.first(where: { $0.name == "extract_links" })!
    }

    func testExtractLinksScriptExists() {
        XCTAssertNotNil(deepResearch.scripts.first(where: { $0.name == "extract_links" }))
    }

    func testExtractLinksIsJavaScript() {
        XCTAssertEqual(extractLinksScript.language, "javascript")
    }

    func testExtractLinksHandlesDoubleQuotes() {
        XCTAssertTrue(extractLinksScript.code.contains(#"["']"#),
                      "extract_links regex must handle double-quoted href attributes")
    }

    func testExtractLinksHandlesSingleQuotes() {
        XCTAssertTrue(extractLinksScript.code.contains("[\"']"),
                      "extract_links regex must handle single-quoted href attributes")
    }

    func testExtractLinksDeduplicates() {
        XCTAssertTrue(extractLinksScript.code.contains("findIndex"),
                      "extract_links should deduplicate URLs")
    }

    func testExtractLinksFiltersEmptyText() {
        XCTAssertTrue(extractLinksScript.code.contains("text.length > 0"),
                      "extract_links should filter out links with empty text")
    }

    func testExtractLinksFiltersNonHTTP() {
        XCTAssertTrue(extractLinksScript.code.contains("startsWith('http')"),
                      "extract_links should filter non-HTTP URLs")
    }

    func testExtractLinksHasDescription() {
        XCTAssertNotNil(extractLinksScript.description)
        XCTAssertFalse(extractLinksScript.description?.isEmpty ?? true)
    }

    // MARK: - Deep Research: summarize_text Script

    private var summarizeTextScript: SkillScript {
        deepResearch.scripts.first(where: { $0.name == "summarize_text" })!
    }

    func testSummarizeTextScriptExists() {
        XCTAssertNotNil(deepResearch.scripts.first(where: { $0.name == "summarize_text" }))
    }

    func testSummarizeTextIsJavaScript() {
        XCTAssertEqual(summarizeTextScript.language, "javascript")
    }

    func testSummarizeTextUsesPositionScoring() {
        XCTAssertTrue(summarizeTextScript.code.contains("1 / (i + 1)"),
                      "summarize_text should use position-based importance scoring")
    }

    func testSummarizeTextUsesLengthScoring() {
        XCTAssertTrue(summarizeTextScript.code.contains("s.length / 200"),
                      "summarize_text should factor in sentence length")
    }

    func testSummarizeTextPreservesOriginalOrder() {
        XCTAssertTrue(summarizeTextScript.code.contains("findIndex"),
                      "summarize_text should restore original sentence order after ranking")
    }

    func testSummarizeTextHandlesEmptyInput() {
        XCTAssertTrue(summarizeTextScript.code.contains("sentences.length === 0"),
                      "summarize_text should handle texts with no extractable sentences")
    }

    func testSummarizeTextHasDescription() {
        XCTAssertNotNil(summarizeTextScript.description)
        XCTAssertFalse(summarizeTextScript.description?.isEmpty ?? true)
    }

    // MARK: - Deep Research: fetch_and_extract Tool

    private var fetchAndExtract: SkillToolDefinition {
        deepResearch.customTools.first(where: { $0.name == "fetch_and_extract" })!
    }

    func testFetchAndExtractToolExists() {
        XCTAssertNotNil(deepResearch.customTools.first(where: { $0.name == "fetch_and_extract" }))
    }

    func testFetchAndExtractHasURLParam() {
        let urlParam = fetchAndExtract.parameters.first(where: { $0.name == "url" })
        XCTAssertNotNil(urlParam)
        XCTAssertEqual(urlParam?.type, "string")
    }

    func testFetchAndExtractHasMaxLengthParam() {
        let param = fetchAndExtract.parameters.first(where: { $0.name == "max_length" })
        XCTAssertNotNil(param)
        XCTAssertEqual(param?.type, "number")
        XCTAssertEqual(param?.required, false, "max_length should be optional")
    }

    func testFetchAndExtractDescriptionMentionsFallback() {
        XCTAssertTrue(fetchAndExtract.description.contains("browser_navigate"),
                      "Tool description should mention browser tools as fallback")
    }

    func testFetchAndExtractErrorMessageSuggestsBrowserFallback() {
        let impl = fetchAndExtract.implementation
        // Both error paths should suggest browser_navigate as alternative
        let browserMentions = impl.components(separatedBy: "browser_navigate").count - 1
        XCTAssertGreaterThanOrEqual(browserMentions, 2,
                      "Both HTTP error and network error paths should suggest browser_navigate")
    }

    func testFetchAndExtractStripsNavigation() {
        let impl = fetchAndExtract.implementation
        XCTAssertTrue(impl.contains("<nav"), "Should strip <nav> elements")
        XCTAssertTrue(impl.contains("<header"), "Should strip <header> elements")
        XCTAssertTrue(impl.contains("<footer"), "Should strip <footer> elements")
    }

    func testFetchAndExtractDecodesHTMLEntities() {
        let impl = fetchAndExtract.implementation
        XCTAssertTrue(impl.contains("&nbsp;"))
        XCTAssertTrue(impl.contains("&amp;"))
        XCTAssertTrue(impl.contains("&lt;"))
        XCTAssertTrue(impl.contains("&gt;"))
        XCTAssertTrue(impl.contains("&quot;"))
        XCTAssertTrue(impl.contains("&#39;"))
    }

    func testFetchAndExtractDefaultMaxLength() {
        XCTAssertTrue(fetchAndExtract.implementation.contains("5000"),
                      "Default max_length should be 5000")
    }

    // MARK: - File Ops

    private var fileOps: BuiltInSkills.ResolvedTemplate {
        allTemplates.first(where: { $0.name == "File Ops" })!
    }

    func testFileOpsSkillExists() {
        XCTAssertNotNil(allTemplates.first(where: { $0.name == "File Ops" }))
    }

    func testFileOpsHasExpectedCustomTools() {
        let names = Set(fileOps.customTools.map(\.name))
        XCTAssertEqual(names, Set(["cp", "mv", "stat", "mkdir", "tree", "touch", "exists"]))
    }

    func testFileOpsToolsHaveNonEmptyImplementations() {
        for tool in fileOps.customTools {
            XCTAssertFalse(tool.implementation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "File Ops tool '\(tool.name)' must have a non-empty implementation")
        }
    }

    func testFileOpsImplementationsUseFsNamespace() {
        for tool in fileOps.customTools {
            XCTAssertTrue(tool.implementation.contains("fs."),
                          "File Ops tool '\(tool.name)' should delegate to the fs namespace")
        }
    }

    func testFileOpsCpHasRequiredParams() {
        let cp = fileOps.customTools.first(where: { $0.name == "cp" })!
        let required = Set(cp.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["src", "dest"]))
    }

    func testFileOpsMvHasRequiredParams() {
        let mv = fileOps.customTools.first(where: { $0.name == "mv" })!
        let required = Set(mv.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["src", "dest"]))
    }

    func testFileOpsContentMentionsFdOps() {
        let content = fileOps.content
        XCTAssertTrue(content.contains("fs.open"),
                      "File Ops skill should document POSIX fd operations")
        XCTAssertTrue(content.contains("fs.seek"),
                      "File Ops skill should document the seek operation")
    }

    func testFileOpsTags() {
        let tags = Set(fileOps.tags)
        XCTAssertTrue(tags.contains("files"))
    }

    // MARK: - Health Plus

    private var healthPlus: BuiltInSkills.ResolvedTemplate {
        allTemplates.first(where: { $0.name == "Health Plus" })!
    }

    func testHealthPlusSkillExists() {
        XCTAssertNotNil(allTemplates.first(where: { $0.name == "Health Plus" }))
    }

    func testHealthPlusHasExpectedCustomTools() {
        let names = Set(healthPlus.customTools.map(\.name))
        XCTAssertEqual(names, Set([
            "read_blood_pressure", "read_blood_glucose", "read_blood_oxygen", "read_body_temperature",
            "write_blood_pressure", "write_blood_glucose", "write_blood_oxygen", "write_body_temperature",
            "write_body_fat", "write_height", "write_heart_rate",
            "write_dietary_carbohydrates", "write_dietary_protein", "write_dietary_fat",
            "write_workout",
        ]))
    }

    func testHealthPlusCustomToolCount() {
        XCTAssertEqual(healthPlus.customTools.count, 15)
    }

    func testHealthPlusToolsHaveNonEmptyImplementations() {
        for tool in healthPlus.customTools {
            XCTAssertFalse(tool.implementation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Health Plus tool '\(tool.name)' must have a non-empty implementation")
        }
    }

    func testHealthPlusImplementationsUseAppleHealthNamespace() {
        for tool in healthPlus.customTools {
            XCTAssertTrue(tool.implementation.contains("apple.health."),
                          "Health Plus tool '\(tool.name)' should delegate to the apple.health namespace")
        }
    }

    func testHealthPlusWriteBloodPressureRequiredParams() {
        let tool = healthPlus.customTools.first(where: { $0.name == "write_blood_pressure" })!
        let required = Set(tool.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["systolic", "diastolic"]))
    }

    func testHealthPlusWriteWorkoutRequiredParams() {
        let tool = healthPlus.customTools.first(where: { $0.name == "write_workout" })!
        let required = Set(tool.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["start_date", "end_date"]))
    }

    func testHealthPlusContentMentionsAppleHealth() {
        XCTAssertTrue(healthPlus.content.contains("apple.health."),
                      "Health Plus skill should document the apple.health namespace")
    }

    func testHealthPlusTags() {
        let tags = Set(healthPlus.tags)
        XCTAssertTrue(tags.contains("health"))
    }

    // MARK: - Skill Builder

    private var skillBuilder: BuiltInSkills.ResolvedTemplate {
        allTemplates.first(where: { $0.name == "Skill Builder" })!
    }

    func testSkillBuilderSkillExists() {
        XCTAssertNotNil(allTemplates.first(where: { $0.name == "Skill Builder" }))
    }

    func testSkillBuilderShipsAuthoringTools() {
        let names = Set(skillBuilder.customTools.map(\.name))
        XCTAssertEqual(names, Set(["scaffold", "add_tool", "add_script"]),
                       "skill-builder ships exactly the three fs.* authoring helpers")
    }

    func testSkillBuilderScaffoldHasRequiredParams() {
        let scaffold = skillBuilder.customTools.first(where: { $0.name == "scaffold" })!
        let required = Set(scaffold.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["slug", "name", "description"]))
    }

    func testSkillBuilderAddToolHasRequiredParams() {
        let addTool = skillBuilder.customTools.first(where: { $0.name == "add_tool" })!
        let required = Set(addTool.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["slug", "tool_name", "description"]))
        // `parameters` is optional — the JSON array can be absent for a
        // zero-arg tool.
        XCTAssertNotNil(addTool.parameters.first(where: { $0.name == "parameters" && !$0.required }))
    }

    func testSkillBuilderAddScriptHasRequiredParams() {
        let addScript = skillBuilder.customTools.first(where: { $0.name == "add_script" })!
        let required = Set(addScript.parameters.filter { $0.required }.map(\.name))
        XCTAssertEqual(required, Set(["slug", "script_name", "description"]))
    }

    func testSkillBuilderHasNoValidateTool() {
        // The proposal intentionally drops `validate.js` from skill-builder —
        // a JS mirror of the Swift validator would drift. The skill body
        // documents `validate_skill` (the top-level LLM tool) instead.
        let names = skillBuilder.customTools.map(\.name)
        XCTAssertFalse(names.contains("validate"),
                       "skill-builder.tools/validate.js was dropped — agents call the top-level validate_skill tool instead.")
    }

    func testSkillBuilderContentDocumentsAuthoringFlow() {
        let content = skillBuilder.content
        XCTAssertTrue(content.contains("validate_skill"))
        XCTAssertTrue(content.contains("install_skill"))
        XCTAssertTrue(content.contains("fs.writeFile") || content.contains("fs."))
        XCTAssertTrue(content.contains("/skills/"))
        // The body should reference all three authoring helpers — they're
        // the documented entry points for steps 2, 3, and 4 of the flow.
        XCTAssertTrue(content.contains("scaffold"))
        XCTAssertTrue(content.contains("add_tool"))
        XCTAssertTrue(content.contains("add_script"))
    }

    func testSkillBuilderTags() {
        XCTAssertTrue(Set(skillBuilder.tags).contains("authoring"))
    }
}
