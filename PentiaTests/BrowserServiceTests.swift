import XCTest
@testable import iClaw

final class BrowserErrorTests: XCTestCase {

    // MARK: - BrowserError Descriptions

    func testInvalidURLError() {
        let error = BrowserError.invalidURL("not-a-url")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not-a-url"))
    }

    func testNavigationTimeoutError() {
        let error = BrowserError.navigationTimeout
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("timeout") ||
                      error.errorDescription!.lowercased().contains("timed out"))
    }

    func testCannotGoBackError() {
        let error = BrowserError.cannotGoBack
        XCTAssertNotNil(error.errorDescription)
    }

    func testCannotGoForwardError() {
        let error = BrowserError.cannotGoForward
        XCTAssertNotNil(error.errorDescription)
    }

    func testJavaScriptError() {
        let error = BrowserError.javaScriptError("ReferenceError: foo is not defined")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("ReferenceError"))
    }

    func testElementNotFoundError() {
        let error = BrowserError.elementNotFound("Element not found: #missing")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("#missing"))
    }

    func testWaitTimeoutError() {
        let error = BrowserError.waitTimeout(".loading-spinner", 10)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains(".loading-spinner"))
        XCTAssertTrue(error.errorDescription!.contains("10"))
    }
}

// MARK: - Selector Resolution

@MainActor
final class BrowserSelectorResolutionTests: XCTestCase {

    func testStandardSelectorPassthrough() {
        let service = BrowserService.shared
        let result = service.resolveSelector("#submit-btn")
        XCTAssertEqual(result, "document.querySelector('#submit-btn')")
    }

    func testStandardSelectorPassthroughAll() {
        let service = BrowserService.shared
        let result = service.resolveSelector(".item", all: true)
        XCTAssertEqual(result, "document.querySelectorAll('.item')")
    }

    func testContainsSelectorDoubleQuotes() {
        let service = BrowserService.shared
        let result = service.resolveSelector("button:contains(\"Submit\")")
        XCTAssertTrue(result.contains("querySelectorAll('button')"))
        XCTAssertTrue(result.contains("indexOf('Submit')"))
        XCTAssertTrue(result.contains(".find("))
        XCTAssertTrue(result.hasSuffix(")||null"))
    }

    func testContainsSelectorSingleQuotes() {
        let service = BrowserService.shared
        let result = service.resolveSelector("button:contains('A类')")
        XCTAssertTrue(result.contains("querySelectorAll('button')"))
        XCTAssertTrue(result.contains("indexOf('A类')"))
    }

    func testContainsSelectorAll() {
        let service = BrowserService.shared
        let result = service.resolveSelector("li:contains(\"active\")", all: true)
        XCTAssertTrue(result.contains("querySelectorAll('li')"))
        XCTAssertTrue(result.contains(".filter("))
        XCTAssertFalse(result.contains("||null"))
    }

    func testContainsSelectorWithCompoundBase() {
        let service = BrowserService.shared
        let result = service.resolveSelector("div.menu button:contains(\"OK\")")
        XCTAssertTrue(result.contains("querySelectorAll('div.menu button')"))
        XCTAssertTrue(result.contains("indexOf('OK')"))
    }

    func testContainsRegexDoesNotMatchPlainSelector() {
        let regex = BrowserService.containsRegex
        let selector = "button.primary"
        let range = NSRange(selector.startIndex..., in: selector)
        XCTAssertNil(regex.firstMatch(in: selector, range: range))
    }

    func testContainsRegexMatchesDoubleQuotes() {
        let regex = BrowserService.containsRegex
        let selector = "button:contains(\"text\")"
        let range = NSRange(selector.startIndex..., in: selector)
        XCTAssertNotNil(regex.firstMatch(in: selector, range: range))
    }

    func testContainsRegexMatchesSingleQuotes() {
        let regex = BrowserService.containsRegex
        let selector = "span:contains('hello')"
        let range = NSRange(selector.startIndex..., in: selector)
        XCTAssertNotNil(regex.firstMatch(in: selector, range: range))
    }
}

// MARK: - JS Error Prefix

final class BrowserJSErrorPrefixTests: XCTestCase {

    func testErrorPrefixDetection() {
        let prefix = "__ICLAW_JS_ERR__:"
        let errorString = "\(prefix)SyntaxError: Unexpected token"
        XCTAssertTrue(errorString.hasPrefix(prefix))
        let msg = String(errorString.dropFirst(prefix.count))
        XCTAssertEqual(msg, "SyntaxError: Unexpected token")
    }

    func testNormalStringDoesNotTriggerPrefix() {
        let prefix = "__ICLAW_JS_ERR__:"
        let normalResult = "{\"ok\":true,\"tag\":\"BUTTON\"}"
        XCTAssertFalse(normalResult.hasPrefix(prefix))
    }
}

// MARK: - JS Escape

@MainActor
final class BrowserJSEscapeTests: XCTestCase {

    func testEscapeSimpleString() {
        let service = BrowserService.shared
        XCTAssertEqual(service.jsEscape("hello"), "'hello'")
    }

    func testEscapeSingleQuote() {
        let service = BrowserService.shared
        XCTAssertEqual(service.jsEscape("it's"), "'it\\'s'")
    }

    func testEscapeBackslash() {
        let service = BrowserService.shared
        XCTAssertEqual(service.jsEscape("a\\b"), "'a\\\\b'")
    }

    func testEscapeNewline() {
        let service = BrowserService.shared
        XCTAssertEqual(service.jsEscape("line1\nline2"), "'line1\\nline2'")
    }
}

// MARK: - Element ID & XPath Resolution

@MainActor
final class BrowserElementIdResolutionTests: XCTestCase {

    func testResolveElementId() {
        let service = BrowserService.shared
        let result = service.resolveElementId("ab3k7")
        XCTAssertEqual(result, "document.querySelector('[data-iclaw-id=' + 'ab3k7' + ']')")
    }

    func testResolveElementIdEscapesSpecialChars() {
        let service = BrowserService.shared
        let result = service.resolveElementId("a'b")
        XCTAssertTrue(result.contains("a\\'b"))
    }

    func testResolveXPathSingle() {
        let service = BrowserService.shared
        let result = service.resolveXPath("//button[@class='submit']")
        XCTAssertTrue(result.contains("document.evaluate"))
        XCTAssertTrue(result.contains("FIRST_ORDERED_NODE_TYPE"))
        XCTAssertTrue(result.contains("singleNodeValue"))
    }

    func testResolveXPathAll() {
        let service = BrowserService.shared
        let result = service.resolveXPath("//input", all: true)
        XCTAssertTrue(result.contains("document.evaluate"))
        XCTAssertTrue(result.contains("ORDERED_NODE_SNAPSHOT_TYPE"))
        XCTAssertTrue(result.contains("snapshotLength"))
    }

    func testResolveTargetElementIdTakesPrecedence() {
        let service = BrowserService.shared
        let result = service.resolveTarget(elementId: "ab3k7", xpath: "//button", selector: "#btn")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("data-iclaw-id"))
        XCTAssertFalse(result!.contains("document.evaluate"))
        XCTAssertFalse(result!.contains("querySelector('#btn')"))
    }

    func testResolveTargetXPathOverSelector() {
        let service = BrowserService.shared
        let result = service.resolveTarget(elementId: nil, xpath: "//button", selector: "#btn")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("document.evaluate"))
    }

    func testResolveTargetFallsBackToSelector() {
        let service = BrowserService.shared
        let result = service.resolveTarget(elementId: nil, xpath: nil, selector: "#btn")
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "document.querySelector('#btn')")
    }

    func testResolveTargetReturnsNilWhenAllNil() {
        let service = BrowserService.shared
        let result = service.resolveTarget(elementId: nil, xpath: nil, selector: nil)
        XCTAssertNil(result)
    }
}

// MARK: - BrowserService Lock Mechanism

@MainActor
final class BrowserServiceLockTests: XCTestCase {

    func testInitialStateUnlocked() {
        let service = BrowserService.shared
        service.forceReleaseLock()
        XCTAssertFalse(service.isAgentControlled)
        XCTAssertNil(service.lockedBySessionId)
        XCTAssertNil(service.lockedByAgentName)
    }

    func testAcquireLockSuccess() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let sessionId = UUID()
        let error = service.acquireLock(sessionId: sessionId, agentName: "TestAgent")
        XCTAssertNil(error, "Should acquire lock successfully")
        XCTAssertTrue(service.isAgentControlled)
        XCTAssertEqual(service.lockedBySessionId, sessionId)
        XCTAssertEqual(service.lockedByAgentName, "TestAgent")

        service.forceReleaseLock()
    }

    func testAcquireLockSameSession() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let sessionId = UUID()
        _ = service.acquireLock(sessionId: sessionId, agentName: "Agent1")
        let error = service.acquireLock(sessionId: sessionId, agentName: "Agent1")
        XCTAssertNil(error, "Same session should re-acquire lock")

        service.forceReleaseLock()
    }

    func testAcquireLockDifferentSessionFails() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let session1 = UUID()
        let session2 = UUID()
        _ = service.acquireLock(sessionId: session1, agentName: "Agent1")
        let error = service.acquireLock(sessionId: session2, agentName: "Agent2")
        XCTAssertNotNil(error, "Different session should fail to acquire lock")
        XCTAssertTrue(error!.contains("Error"))

        service.forceReleaseLock()
    }

    func testReleaseLock() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let sessionId = UUID()
        _ = service.acquireLock(sessionId: sessionId, agentName: "Agent")
        XCTAssertTrue(service.isAgentControlled)

        service.releaseLock(sessionId: sessionId)
        XCTAssertFalse(service.isAgentControlled)
    }

    func testReleaseLockWrongSession() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let session1 = UUID()
        let session2 = UUID()
        _ = service.acquireLock(sessionId: session1, agentName: "Agent1")

        service.releaseLock(sessionId: session2)
        XCTAssertTrue(service.isAgentControlled, "Wrong session should not release lock")

        service.forceReleaseLock()
    }

    func testForceReleaseLock() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let sessionId = UUID()
        _ = service.acquireLock(sessionId: sessionId, agentName: "Agent")
        service.forceReleaseLock()
        XCTAssertFalse(service.isAgentControlled)
        XCTAssertNil(service.lockedBySessionId)
    }

    func testRefreshLock() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let sessionId = UUID()
        _ = service.acquireLock(sessionId: sessionId, agentName: "Agent")
        service.refreshLock(sessionId: sessionId)
        XCTAssertTrue(service.isAgentControlled)

        service.forceReleaseLock()
    }

    func testRefreshLockWrongSession() {
        let service = BrowserService.shared
        service.forceReleaseLock()

        let session1 = UUID()
        let session2 = UUID()
        _ = service.acquireLock(sessionId: session1, agentName: "Agent1")

        service.refreshLock(sessionId: session2)
        XCTAssertEqual(service.lockedBySessionId, session1)

        service.forceReleaseLock()
    }
}
