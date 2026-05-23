import Foundation

struct BrowserTools {
    let sessionId: UUID
    let agentName: String

    func navigate(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        guard let url = arguments["url"] as? String else {
            if let action = arguments["action"] as? String {
                return await handleAction(action)
            }
            return "[Error] Missing required parameter: url or action"
        }

        if let (agentId, filename) = AgentFileManager.parseFileReference(url) {
            let ext = (filename as NSString).pathExtension.lowercased()
            guard ["html", "htm"].contains(ext) else {
                return "[Error] Only HTML files can be opened in the browser. Got: \(filename)"
            }
            let fileURL = AgentFileManager.shared.fileURL(agentId: agentId, name: filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return "[Error] File not found: \(filename)"
            }
            let result = await BrowserService.shared.loadAgentFile(fileURL: fileURL, agentId: agentId)
            await refreshLock()
            return formatResult(result)
        }

        let result = await BrowserService.shared.navigate(to: url)
        await refreshLock()
        return formatResult(result)
    }

    func getPageInfo(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let includeContent = arguments["include_content"] as? Bool ?? false
        let simplified = arguments["simplified"] as? Bool ?? true
        let result = await BrowserService.shared.getPageInfo(includeHTML: includeContent, simplified: simplified)
        await refreshLock()
        return formatResult(result)
    }

    func click(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let (eid, xp, sel) = extractTarget(arguments)
        guard eid != nil || xp != nil || sel != nil else {
            return "[Error] Provide 'element_id', 'xpath', or 'selector'"
        }
        let result = await BrowserService.shared.click(elementId: eid, xpath: xp, selector: sel)
        await refreshLock()
        return formatResult(result)
    }

    func input(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let (eid, xp, sel) = extractTarget(arguments)
        guard eid != nil || xp != nil || sel != nil else {
            return "[Error] Provide 'element_id', 'xpath', or 'selector'"
        }
        guard let text = arguments["text"] as? String else {
            return "[Error] Missing required parameter: text"
        }
        let clear = arguments["clear_first"] as? Bool ?? true
        let result = await BrowserService.shared.input(elementId: eid, xpath: xp, selector: sel, text: text, clearFirst: clear)
        await refreshLock()
        return formatResult(result)
    }

    func select(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let (eid, xp, sel) = extractTarget(arguments)
        guard eid != nil || xp != nil || sel != nil else {
            return "[Error] Provide 'element_id', 'xpath', or 'selector'"
        }
        guard let value = arguments["value"] as? String else {
            return "[Error] Missing required parameter: value"
        }
        let result = await BrowserService.shared.select(elementId: eid, xpath: xp, selector: sel, value: value)
        await refreshLock()
        return formatResult(result)
    }

    func extract(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let (eid, xp, sel) = extractTarget(arguments)
        guard eid != nil || xp != nil || sel != nil else {
            return "[Error] Provide 'element_id', 'xpath', or 'selector'"
        }
        let attribute = arguments["attribute"] as? String
        let result = await BrowserService.shared.extract(elementId: eid, xpath: xp, selector: sel, attribute: attribute)
        await refreshLock()
        return formatResult(result)
    }

    func executeJS(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        guard let code = arguments["code"] as? String else {
            return "[Error] Missing required parameter: code"
        }
        let result = await BrowserService.shared.executeUserJavaScript(code)
        await refreshLock()
        return formatResult(result)
    }

    func waitForElement(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let (eid, xp, sel) = extractTarget(arguments)
        guard eid != nil || xp != nil || sel != nil else {
            return "[Error] Provide 'element_id', 'xpath', or 'selector'"
        }
        let timeout = arguments["timeout"] as? Double ?? 10
        let clampedTimeout = min(max(timeout, 1), 30)
        let result = await BrowserService.shared.waitForElement(elementId: eid, xpath: xp, selector: sel, timeout: clampedTimeout)
        await refreshLock()
        return formatResult(result)
    }

    func scroll(arguments: [String: Any]) async -> String {
        if let err = await checkLock() { return err }
        let direction = arguments["direction"] as? String ?? "down"
        let pixels = arguments["pixels"] as? Int ?? 500
        let result = await BrowserService.shared.scroll(direction: direction, pixels: pixels)
        await refreshLock()
        return formatResult(result)
    }

    // MARK: - Lock

    private func checkLock() async -> String? {
        await BrowserService.shared.acquireLock(sessionId: sessionId, agentName: agentName)
    }

    private func refreshLock() async {
        await BrowserService.shared.refreshLock(sessionId: sessionId)
    }

    // MARK: - Private

    private func extractTarget(_ arguments: [String: Any]) -> (String?, String?, String?) {
        let elementId = arguments["element_id"] as? String
        let xpath = arguments["xpath"] as? String
        let selector = arguments["selector"] as? String
        return (elementId, xpath, selector)
    }

    private func handleAction(_ action: String) async -> String {
        switch action {
        case "back":
            return formatResult(await BrowserService.shared.goBack())
        case "forward":
            return formatResult(await BrowserService.shared.goForward())
        case "reload":
            return formatResult(await BrowserService.shared.reload())
        default:
            return "[Error] Unknown action: \(action). Use 'back', 'forward', or 'reload'."
        }
    }

    private func formatResult(_ result: Result<String, BrowserError>) -> String {
        switch result {
        case .success(let msg): return msg
        case .failure(let err): return "[Error] \(err.localizedDescription)"
        }
    }
}
