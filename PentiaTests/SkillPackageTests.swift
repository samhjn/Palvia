import XCTest
@testable import iClaw

final class SkillPackageTests: XCTestCase {

    // MARK: - Scratch directory helpers

    private var scratchRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SkillPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = scratchRoot, FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        scratchRoot = nil
        try super.tearDownWithError()
    }

    private func makeSkillDir(slug: String) throws -> URL {
        let dir = scratchRoot.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Frontmatter parser

    func testFrontmatterParsesSimpleFields() throws {
        let src = """
        ---
        name: Deep Research
        description: Multi-source research with source triangulation.
        ---

        # Body
        hello
        """
        let (fm, body, _) = try SkillFrontmatterParser.parse(src)
        XCTAssertEqual(fm.name, "Deep Research")
        XCTAssertEqual(fm.description, "Multi-source research with source triangulation.")
        XCTAssertTrue(body.hasPrefix("# Body"))
    }

    func testFrontmatterParsesIClawBlock() throws {
        let src = """
        ---
        name: Foo
        description: Bar
        iclaw:
          version: "1.0"
          slash: foo
          tags: [research, analysis]
        ---
        body
        """
        let (fm, _, _) = try SkillFrontmatterParser.parse(src)
        XCTAssertEqual(fm.iclaw.version, "1.0")
        XCTAssertEqual(fm.iclaw.slash, "foo")
        XCTAssertEqual(fm.iclaw.tags, ["research", "analysis"])
    }

    func testFrontmatterParsesConfigList() throws {
        let src = """
        ---
        name: Foo
        description: Bar
        iclaw:
          config:
            - { key: api_key, type: string, required: true }
            - { key: max_len, type: number, default: "5000" }
        ---
        """
        let (fm, _, _) = try SkillFrontmatterParser.parse(src)
        XCTAssertEqual(fm.iclaw.configRaw.count, 2)
        XCTAssertEqual(fm.iclaw.configRaw[0]["key"], "api_key")
        XCTAssertEqual(fm.iclaw.configRaw[1]["default"], "5000")
    }

    func testFrontmatterRejectsMissingOpener() {
        let src = "no frontmatter here"
        XCTAssertThrowsError(try SkillFrontmatterParser.parse(src))
    }

    func testFrontmatterRejectsMissingCloser() {
        let src = "---\nname: Foo\n"
        XCTAssertThrowsError(try SkillFrontmatterParser.parse(src))
    }

    func testOverlayParsesPartialFields() throws {
        let src = """
        ---
        display_name: 深度研究
        description: 多源研究方法。
        ---

        # 深度研究技能
        翻译后的正文
        """
        let overlay = try SkillFrontmatterParser.parseOverlay(src)
        XCTAssertEqual(overlay.displayName, "深度研究")
        XCTAssertEqual(overlay.description, "多源研究方法。")
        XCTAssertTrue(overlay.body.contains("深度研究技能"))
    }

    // MARK: - JS META parser

    func testMetaParserExtractsBasicMeta() throws {
        let src = #"""
        const META = {
          name: "fetch_and_extract",
          description: "Quick plain-text fetch with HTML stripping.",
          parameters: [
            { name: "url", type: "string", required: true },
            { name: "max_length", type: "number", required: false },
          ],
        };

        const url = args.url;
        console.log("hello");
        """#
        let meta = try SkillJSMetaParser.parse(src)
        XCTAssertEqual(meta.name, "fetch_and_extract")
        XCTAssertEqual(meta.description, "Quick plain-text fetch with HTML stripping.")
        XCTAssertEqual(meta.parameters.count, 2)
        XCTAssertEqual(meta.parameters[0].name, "url")
        XCTAssertEqual(meta.parameters[0].type, "string")
        XCTAssertTrue(meta.parameters[0].required)
        XCTAssertFalse(meta.parameters[1].required)
    }

    func testMetaParserAcceptsSingleQuotesAndComments() throws {
        let src = """
        // tools/foo.js
        /* block
           comment */
        let META = {
          name: 'my_tool',
          description: 'does a thing',
          parameters: []
        };
        """
        let meta = try SkillJSMetaParser.parse(src)
        XCTAssertEqual(meta.name, "my_tool")
        XCTAssertEqual(meta.description, "does a thing")
        XCTAssertEqual(meta.parameters.count, 0)
    }

    func testMetaParserReportsMissingName() {
        let src = """
        const META = {
          description: "missing name"
        };
        """
        XCTAssertThrowsError(try SkillJSMetaParser.parse(src))
    }

    func testMetaParserReportsNotFound() {
        let src = "console.log('hi');"
        XCTAssertThrowsError(try SkillJSMetaParser.parse(src)) { err in
            XCTAssertEqual(err as? JSMetaError, .notFound)
        }
    }

    func testMetaParserHandlesEscapedStrings() throws {
        let src = #"""
        const META = {
          name: "greet",
          description: "Says \"hello\" to a user.\nMultiline OK via escape.",
          parameters: [{ name: "who", type: "string" }]
        };
        """#
        let meta = try SkillJSMetaParser.parse(src)
        XCTAssertTrue(meta.description.contains("\""))
        XCTAssertTrue(meta.description.contains("\n"))
    }

    func testMetaParserTracksLineNumbers() throws {
        let src = #"""
        // line 1
        // line 2
        const META = {
          name: "foo",
          description: "bar",
          parameters: []
        };
        """#
        let meta = try SkillJSMetaParser.parse(src)
        XCTAssertEqual(meta.metaLineRange.lowerBound, 3)
        XCTAssertGreaterThanOrEqual(meta.metaLineRange.upperBound, 7)
    }

    // MARK: - Slug derivation

    func testSlugFromName() {
        XCTAssertEqual(SkillPackage.derivedSlug(forName: "Deep Research"), "deep-research")
        XCTAssertEqual(SkillPackage.derivedSlug(forName: "File Ops"), "file-ops")
        XCTAssertEqual(SkillPackage.derivedSlug(forName: "Skill--Builder   v2!!"), "skill-builder-v2")
    }

    func testSlugOverrideRespected() {
        XCTAssertEqual(
            SkillPackage.derivedSlug(forName: "Some Skill", override: "custom_slug"),
            "custom-slug"
        )
    }

    // MARK: - Package validation

    func testValidateMissingSkillMdIsError() throws {
        let dir = try makeSkillDir(slug: "empty")
        let report = SkillPackage.validate(at: dir)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.errors.first?.code, .skillMdMissing)
    }

    func testValidateValidMinimalSkill() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: A tiny greeting skill.
            ---

            # Hello
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.ok, "Unexpected errors: \(report.errors)")
    }

    func testValidateSlugMismatchIsError() throws {
        // Directory name is `wrong-slug` but name would derive `hello`.
        let dir = try makeSkillDir(slug: "wrong-slug")
        try write(
            """
            ---
            name: Hello
            description: A tiny greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.errors.contains(where: { $0.code == .slugMismatch }))
    }

    func testValidateNameTooLongIsError() throws {
        let longName = String(repeating: "a", count: 65)
        let dir = try makeSkillDir(slug: SkillPackage.derivedSlug(forName: longName))
        try write(
            """
            ---
            name: \(longName)
            description: ok
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.errors.contains(where: { $0.code == .fieldTooLong }))
    }

    func testValidateDescriptionTooLongIsError() throws {
        let longDesc = String(repeating: "x", count: 201)
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: \(longDesc)
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.errors.contains(where: { $0.code == .fieldTooLong }))
    }

    func testValidateDescriptionLongWarning() throws {
        let longishDesc = String(repeating: "x", count: 180)
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: \(longishDesc)
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.ok, "Unexpected errors: \(report.errors)")
        XCTAssertTrue(report.warnings.contains(where: { $0.code == .descriptionLong }))
    }

    func testValidateToolWithValidMeta() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write(
            #"""
            const META = {
              name: "greet",
              description: "Greet the user by name.",
              parameters: [{ name: "who", type: "string", required: true }]
            };
            console.log(`Hello, ${args.who}!`);
            """#,
            to: dir.appendingPathComponent("tools/greet.js")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.ok, "Unexpected errors: \(report.errors)")
    }

    func testValidateToolWithBadParamTypeIsError() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write(
            #"""
            const META = {
              name: "greet",
              description: "Greet the user by name.",
              parameters: [{ name: "who", type: "strng" }]
            };
            console.log("hi");
            """#,
            to: dir.appendingPathComponent("tools/greet.js")
        )
        let report = SkillPackage.validate(at: dir)
        let bad = report.errors.first(where: { $0.code == .badParamType })
        XCTAssertNotNil(bad, "Expected bad_param_type error")
        XCTAssertTrue(bad!.message.contains("string"), "Typo hint should suggest `string`")
    }

    func testValidateToolWithoutMetaIsError() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write("console.log('no meta here');",
                  to: dir.appendingPathComponent("tools/raw.js"))
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.errors.contains(where: { $0.code == .metaMissing }))
    }

    func testValidateDuplicateToolNameIsError() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let dup = #"""
        const META = {
          name: "greet",
          description: "Greet the user by name.",
          parameters: []
        };
        console.log("hi");
        """#
        try write(dup, to: dir.appendingPathComponent("tools/a.js"))
        try write(dup, to: dir.appendingPathComponent("tools/b.js"))
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.errors.contains(where: { $0.code == .metaDuplicate }))
    }

    func testValidateShadowingCoreToolIsError() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write(
            #"""
            const META = {
              name: "read_config",
              description: "This would shadow the core tool.",
              parameters: []
            };
            console.log("hi");
            """#,
            to: dir.appendingPathComponent("tools/read_config.js")
        )
        let report = SkillPackage.validate(at: dir, coreToolNames: ["read_config"])
        XCTAssertTrue(report.errors.contains(where: { $0.code == .toolNameShadowsCore }))
    }

    func testValidateScriptWithoutFirstLineCommentIsWarning() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write("const x = 1; console.log(x);",
                  to: dir.appendingPathComponent("scripts/foo.js"))
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.ok, "Unexpected errors: \(report.errors)")
        XCTAssertTrue(report.warnings.contains(where: { $0.code == .noDescriptionComment }))
    }

    func testValidateNonAsciiTagWarns() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            iclaw:
              tags: [研究, analysis]
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let report = SkillPackage.validate(at: dir)
        XCTAssertTrue(report.warnings.contains(where: { $0.code == .nonAsciiTag }))
    }

    // MARK: - Locale overlay resolution

    func testOverlayAppliedForPreferredLocale() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: English description.
            ---
            English body.
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write(
            """
            ---
            display_name: 你好
            description: 中文描述。
            ---
            中文正文。
            """,
            to: dir.appendingPathComponent("SKILL.zh-Hans.md")
        )
        let (pkg, report) = SkillPackage.parse(at: dir, preferredLocales: ["zh-Hans", "en"])
        XCTAssertTrue(report.ok)
        XCTAssertEqual(pkg?.displayName, "你好")
        XCTAssertEqual(pkg?.description, "中文描述。")
        XCTAssertTrue(pkg?.body.contains("中文正文") ?? false)
    }

    func testOverlayFallsBackToBaseLanguage() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: English description.
            ---
            English body.
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write(
            """
            ---
            display_name: 你好
            description: zh 描述.
            ---
            zh 正文.
            """,
            to: dir.appendingPathComponent("SKILL.zh.md")
        )
        let (pkg, _) = SkillPackage.parse(at: dir, preferredLocales: ["zh-Hans"])
        XCTAssertEqual(pkg?.displayName, "你好")
    }

    func testOverlayFallsBackToCanonicalWhenMissing() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: English description.
            ---
            English body.
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        let (pkg, _) = SkillPackage.parse(at: dir, preferredLocales: ["ja"])
        XCTAssertEqual(pkg?.description, "English description.")
    }

    func testToolOverlayAppliesTranslations() throws {
        let dir = try makeSkillDir(slug: "hello")
        try write(
            """
            ---
            name: Hello
            description: Greeting skill.
            ---
            """,
            to: dir.appendingPathComponent("SKILL.md")
        )
        try write(
            #"""
            const META = {
              name: "greet",
              description: "Greet the user by name.",
              parameters: [{ name: "who", type: "string", description: "The person" }]
            };
            console.log("hi");
            """#,
            to: dir.appendingPathComponent("tools/greet.js")
        )
        try write(
            """
            {
              "description": "按名字向用户问好。",
              "parameters": {
                "who": { "description": "目标用户" }
              }
            }
            """,
            to: dir.appendingPathComponent("tools/greet.zh-Hans.json")
        )
        let (pkg, _) = SkillPackage.parse(at: dir, preferredLocales: ["zh-Hans"])
        XCTAssertEqual(pkg?.tools.first?.meta.description, "按名字向用户问好。")
        XCTAssertEqual(pkg?.tools.first?.meta.parameters.first?.description, "目标用户")
    }

    // MARK: - Report serialization

    func testReportJSONIsStable() throws {
        let report = ValidationReport(
            slug: "s",
            errors: [.init(severity: .error, file: "SKILL.md", line: 2, code: .missingField, message: "x")],
            warnings: []
        )
        let json = report.jsonString()
        XCTAssertTrue(json.contains("\"code\""))
        XCTAssertTrue(json.contains("\"missing_field\""))
        XCTAssertTrue(json.contains("\"slug\""))
    }
}
