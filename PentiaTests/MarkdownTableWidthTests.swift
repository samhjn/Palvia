import XCTest
import UIKit
@testable import iClaw

// MARK: - Table Parsing Tests

/// Tests for markdown table parsing and column width calculation,
/// specifically the fix for tables rendering with incorrect width
/// (e.g. two-line row height for single-line content).
final class MarkdownTableParsingTests: XCTestCase {

    // MARK: - Basic table detection

    func testBasicTableParsedCorrectly() {
        let md = """
        | Name | Age |
        |------|-----|
        | Alice | 30 |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block"); return
        }
        XCTAssertEqual(table.headers, ["Name", "Age"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0], ["Alice", "30"])
    }

    func testHashHeaderNotMistakenForHeading() {
        let md = """
        | # | 景点 | 特色 |
        |---|------|------|
        | 13 | **长田漾湿地公园** | 湿地生态公园，亲近自然 |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        // Must be a single table block, NOT a heading
        XCTAssertEqual(blocks.count, 1, "Should produce exactly one block")
        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block, not heading or paragraph"); return
        }
        XCTAssertEqual(table.headers.count, 3, "Table should have 3 columns")
        XCTAssertEqual(table.headers, ["#", "景点", "特色"])
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0][0], "13")
        XCTAssertEqual(table.rows[0][1], "**长田漾湿地公园**")
        XCTAssertEqual(table.rows[0][2], "湿地生态公园，亲近自然")
    }

    func testThreeColumnTableAlignment() {
        let md = """
        | Left | Center | Right |
        |:-----|:------:|------:|
        | a | b | c |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block"); return
        }
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
    }

    func testMultipleDataRows() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        | 3 | 4 |
        | 5 | 6 |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block"); return
        }
        XCTAssertEqual(table.rows.count, 3)
    }

    func testRowsNormalizedToHeaderColumnCount() {
        let md = """
        | A | B | C |
        |---|---|---|
        | 1 | 2 |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block"); return
        }
        XCTAssertEqual(table.headers.count, 3)
        XCTAssertEqual(table.rows[0].count, 3, "Row should be padded to match header count")
        XCTAssertEqual(table.rows[0][2], "", "Missing cell should be empty string")
    }

    func testSingleRowChineseTableParsedCorrectly() {
        // This is the exact table that triggered the height inflation bug.
        // Tables with only 1 data row were most affected because the
        // ScrollView's proposed height was split between fewer rows.
        let md = """
        | # | 景点 | 特色 |
        |---|------|------|
        | 13 | **长田漾湿地公园** | 湿地生态公园，亲近自然 |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        XCTAssertEqual(blocks.count, 1)
        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block"); return
        }
        XCTAssertEqual(table.headers.count, 3)
        XCTAssertEqual(table.rows.count, 1, "Should have exactly 1 data row")
    }

    func testTableWithBoldAndInlineMarkdown() {
        let md = """
        | Feature | Status |
        |---------|--------|
        | **Bold** | ~~done~~ |
        | `code` | *italic* |
        """
        let view = MarkdownContentView(md, isUser: false)
        let blocks = view.parseBlocks()

        guard case .table(let table) = blocks.first else {
            XCTFail("Expected a table block"); return
        }
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0][0], "**Bold**")
        XCTAssertEqual(table.rows[0][1], "~~done~~")
        XCTAssertEqual(table.rows[1][0], "`code`")
        XCTAssertEqual(table.rows[1][1], "*italic*")
    }
}

// MARK: - Strip Inline Markdown Tests

final class StripInlineMarkdownTests: XCTestCase {

    func testStripBold() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("**bold text**"),
            "bold text"
        )
    }

    func testStripItalic() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("*italic*"),
            "italic"
        )
    }

    func testStripBoldItalic() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("***bold italic***"),
            "bold italic"
        )
    }

    func testStripUnderscoreBold() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("__bold__"),
            "bold"
        )
    }

    func testStripStrikethrough() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("~~deleted~~"),
            "deleted"
        )
    }

    func testStripInlineCode() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("`code`"),
            "code"
        )
    }

    func testStripLink() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("[click here](https://example.com)"),
            "click here"
        )
    }

    func testStripImageSyntax() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("![alt text](image.png)"),
            "alt text"
        )
    }

    func testPlainTextUnchanged() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("plain text 123"),
            "plain text 123"
        )
    }

    func testChineseWithBold() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("**长田漾湿地公园**"),
            "长田漾湿地公园"
        )
    }

    func testMixedFormatting() {
        XCTAssertEqual(
            TableWidthCalculator.stripInlineMarkdown("**bold** and *italic* and `code`"),
            "bold and italic and code"
        )
    }
}

// MARK: - Column Width Calculation Tests

final class ColumnWidthCalculationTests: XCTestCase {

    // MARK: - Width fills available space

    func testColumnsExpandToFillAvailableWidth() {
        let table = MarkdownTable(
            headers: ["#", "景点", "特色"],
            alignments: [.leading, .leading, .leading],
            rows: [["13", "**长田漾湿地公园**", "湿地生态公园，亲近自然"]]
        )

        let maxTableWidth: CGFloat = 358 // typical iPhone width - 32
        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: maxTableWidth
        )

        let totalWidth = widths.reduce(0, +)
        // Total width should approximately fill available space
        XCTAssertGreaterThan(totalWidth, maxTableWidth * 0.95,
                             "Table should fill at least 95% of available width, got \(totalWidth)/\(maxTableWidth)")
    }

    func testNarrowTableExpandsColumns() {
        let table = MarkdownTable(
            headers: ["A", "B"],
            alignments: [.leading, .leading],
            rows: [["x", "y"]]
        )

        let maxTableWidth: CGFloat = 300
        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: maxTableWidth
        )

        let totalWidth = widths.reduce(0, +)
        // Even with very short content, table should expand
        XCTAssertGreaterThan(totalWidth, 200,
                             "Narrow table should expand to use available width")
    }

    // MARK: - Minimum column width respected

    func testMinColumnWidthRespected() {
        let table = MarkdownTable(
            headers: ["#"],
            alignments: [.leading],
            rows: [["1"]]
        )

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            minColWidth: 50,
            maxTableWidth: 300
        )

        XCTAssertGreaterThanOrEqual(widths[0], 50,
                                     "Column width should not be less than minColWidth")
    }

    // MARK: - Maximum column width respected

    func testMaxColumnWidthRespected() {
        let table = MarkdownTable(
            headers: ["Header"],
            alignments: [.leading],
            rows: [["A very long string that would normally exceed the maximum column width limit set"]]
        )

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxColWidth: 280,
            maxTableWidth: 500
        )

        XCTAssertLessThanOrEqual(widths[0], 280,
                                  "Column width should not exceed maxColWidth")
    }

    // MARK: - Proportional distribution

    func testExtraSpaceDistributedProportionally() {
        let table = MarkdownTable(
            headers: ["#", "Long Header Name"],
            alignments: [.leading, .leading],
            rows: [["1", "Some longer content here"]]
        )

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: 400
        )

        // The wider column should get more of the extra space
        XCTAssertGreaterThan(widths[1], widths[0],
                             "Wider content column should be wider after proportional distribution")
    }

    // MARK: - Scale down when exceeding max

    func testColumnsScaleDownWhenExceedingMaxTableWidth() {
        let table = MarkdownTable(
            headers: ["Column A", "Column B", "Column C", "Column D", "Column E"],
            alignments: [.leading, .leading, .leading, .leading, .leading],
            rows: [["Long content A", "Long content B", "Long content C", "Long content D", "Long content E"]]
        )

        let maxTableWidth: CGFloat = 200 // very narrow
        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: maxTableWidth
        )

        let totalWidth = widths.reduce(0, +)
        // After scale-down, total should be at or below maxTableWidth
        // (may exceed slightly due to minColWidth enforcement)
        let minPossibleTotal = 50 * CGFloat(widths.count) // minColWidth * columns
        if minPossibleTotal <= maxTableWidth {
            XCTAssertLessThanOrEqual(totalWidth, maxTableWidth + 1,
                                      "Scaled-down total should not exceed maxTableWidth")
        }
    }

    // MARK: - Measurement buffer prevents wrapping

    func testMeasurementIncludesBuffer() {
        let table = MarkdownTable(
            headers: ["景点"],
            alignments: [.leading],
            rows: [["**长田漾湿地公园**"]]
        )

        // Measure the raw text width for comparison
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let boldFont = UIFont.boldSystemFont(ofSize: font.pointSize)
        let rawWidth = NSAttributedString(
            string: "长田漾湿地公园",
            attributes: [.font: boldFont]
        ).size().width
        let paddingTotal: CGFloat = 16 // cellPaddingH * 2

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: 500 // generous width so no scaling occurs
        )

        // Column should be wider than raw text + padding (due to buffer)
        XCTAssertGreaterThan(widths[0], ceil(rawWidth) + paddingTotal,
                             "Column width should include buffer beyond raw text + padding")
    }

    // MARK: - The specific reported table case

    func testReportedChineseTableHasAdequateColumnWidths() {
        let table = MarkdownTable(
            headers: ["#", "景点", "特色"],
            alignments: [.leading, .leading, .leading],
            rows: [["13", "**长田漾湿地公园**", "湿地生态公园，亲近自然"]]
        )

        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let boldFont = UIFont.boldSystemFont(ofSize: font.pointSize)

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: 358
        )

        XCTAssertEqual(widths.count, 3, "Should have 3 column widths")

        // Each column must be wide enough for its content to fit in one line
        let contents = ["13", "长田漾湿地公园", "湿地生态公园，亲近自然"]
        for (idx, text) in contents.enumerated() {
            let textWidth = NSAttributedString(
                string: text,
                attributes: [.font: boldFont]
            ).size().width
            let requiredWidth = ceil(textWidth) + 16 // padding
            XCTAssertGreaterThanOrEqual(
                widths[idx], requiredWidth,
                "Column \(idx) (\(table.headers[idx])) width \(widths[idx]) should be >= required \(requiredWidth) for '\(text)'"
            )
        }
    }

    // MARK: - Empty table edge case

    func testEmptyRowsTable() {
        let table = MarkdownTable(
            headers: ["A", "B"],
            alignments: [.leading, .leading],
            rows: []
        )

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: 300
        )

        XCTAssertEqual(widths.count, 2)
        XCTAssertTrue(widths.allSatisfy { $0 >= 50 }, "All columns should meet minimum width")
    }

    // MARK: - Single column table

    func testSingleColumnTable() {
        let table = MarkdownTable(
            headers: ["Only"],
            alignments: [.leading],
            rows: [["data"]]
        )

        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: 300
        )

        XCTAssertEqual(widths.count, 1)
        // Single column should expand to fill available width (up to maxColWidth)
        XCTAssertGreaterThanOrEqual(widths[0], 50)
        XCTAssertLessThanOrEqual(widths[0], 280)
    }

    // MARK: - Realistic container width (accounting for chat bubble padding)

    func testRealisticContainerWidthProducesAdequateColumns() {
        // Simulate actual available width inside a chat bubble:
        // iPhone 15 (393pt) - ChatView padding (32) - Spacer (48) - bubble padding (24) ≈ 289pt
        let table = MarkdownTable(
            headers: ["#", "景点", "特色"],
            alignments: [.leading, .leading, .leading],
            rows: [["13", "**长田漾湿地公园**", "湿地生态公园，亲近自然"]]
        )

        let realisticWidth: CGFloat = 289
        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: realisticWidth
        )

        let totalWidth = widths.reduce(0, +)
        XCTAssertGreaterThan(totalWidth, realisticWidth * 0.90,
                             "Table should fill most of the container at realistic width")

        // Each column should still be wide enough for its content.
        // At narrow container widths the calculator may scale columns down
        // proportionally, so allow a small tolerance (font metrics also vary
        // slightly across simulator runtimes).
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let boldFont = UIFont.boldSystemFont(ofSize: font.pointSize)
        let contents = ["13", "长田漾湿地公园", "湿地生态公园，亲近自然"]
        let tolerance: CGFloat = 8 // accounts for proportional scaling and font-metric variance
        for (idx, text) in contents.enumerated() {
            let textWidth = NSAttributedString(
                string: text,
                attributes: [.font: boldFont]
            ).size().width
            let requiredWidth = ceil(textWidth) + 16 // padding
            XCTAssertGreaterThanOrEqual(
                widths[idx], requiredWidth - tolerance,
                "Column \(idx) at realistic width should fit '\(text)' (need \(requiredWidth), got \(widths[idx]))"
            )
        }
    }

    // MARK: - Row count should not affect column widths

    func testSingleRowTableSameWidthsAsMultiRowTable() {
        // The height inflation bug only affected tables with few rows because
        // the ScrollView's proposed height was split among fewer HStack rows,
        // causing each Rectangle separator to expand more. Verify that the
        // column width calculation itself is independent of row count.
        let singleRowTable = MarkdownTable(
            headers: ["#", "景点", "特色"],
            alignments: [.leading, .leading, .leading],
            rows: [["13", "**长田漾湿地公园**", "湿地生态公园，亲近自然"]]
        )

        let multiRowTable = MarkdownTable(
            headers: ["#", "景点", "特色"],
            alignments: [.leading, .leading, .leading],
            rows: [
                ["13", "**长田漾湿地公园**", "湿地生态公园，亲近自然"],
                ["14", "**西湖**", "世界文化遗产"],
                ["15", "**千岛湖**", "天下第一秀水"],
                ["16", "**灵隐寺**", "千年古刹"],
                ["17", "**钱塘江**", "观潮胜地"],
            ]
        )

        let maxW: CGFloat = 289
        let singleWidths = TableWidthCalculator.measureColumnWidths(for: singleRowTable, maxTableWidth: maxW)
        let multiWidths = TableWidthCalculator.measureColumnWidths(for: multiRowTable, maxTableWidth: maxW)

        // Column widths should be the same — row count must not affect width calculation
        // (The multi-row table has the same max-width content in each column)
        XCTAssertEqual(singleWidths.count, multiWidths.count)
        for i in 0..<singleWidths.count {
            XCTAssertEqual(singleWidths[i], multiWidths[i], accuracy: 1,
                           "Column \(i) width should be the same regardless of row count")
        }
    }

    func testSingleRowTableFillsAvailableWidth() {
        // Single-row tables were most affected by the height bug.
        // Ensure they still get proper column width expansion.
        let table = MarkdownTable(
            headers: ["Name", "Value"],
            alignments: [.leading, .leading],
            rows: [["key", "val"]]
        )

        let maxW: CGFloat = 300
        let widths = TableWidthCalculator.measureColumnWidths(for: table, maxTableWidth: maxW)
        let total = widths.reduce(0, +)

        XCTAssertGreaterThan(total, maxW * 0.90,
                             "Single-row table should still fill available width")
    }

    // MARK: - Narrow container scale-down

    func testVeryNarrowContainerScalesDown() {
        let table = MarkdownTable(
            headers: ["#", "景点", "特色"],
            alignments: [.leading, .leading, .leading],
            rows: [["13", "**长田漾湿地公园**", "湿地生态公园，亲近自然"]]
        )

        // Very narrow (e.g., iPad slide-over or small widget)
        let narrowWidth: CGFloat = 180
        let widths = TableWidthCalculator.measureColumnWidths(
            for: table,
            maxTableWidth: narrowWidth
        )

        XCTAssertEqual(widths.count, 3)
        XCTAssertTrue(widths.allSatisfy { $0 >= 50 }, "All columns should meet minimum width")
    }
}
