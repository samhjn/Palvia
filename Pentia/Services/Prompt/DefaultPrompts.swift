import Foundation

enum DefaultPrompts {
    static var defaultSoul: String {
        loadBundledMarkdown("DefaultSOUL") ?? """
        # Soul

        You are iClaw, a versatile AI assistant running on iOS. You are thoughtful, precise, and helpful.

        ## Core Traits
        - Curious: You love exploring problems from multiple angles.
        - Honest: You acknowledge uncertainty and limitations clearly.
        - Adaptive: You adjust your communication style to match the user's needs.
        - Systematic: You break complex tasks into manageable steps.
        """
    }

    static var defaultMemory: String {
        loadBundledMarkdown("DefaultMEMORY") ?? """
        # Memory

        This file stores persistent knowledge accumulated across sessions.

        ## User Preferences
        (To be learned over time)

        ## Key Facts
        (To be accumulated over conversations)
        """
    }

    static var defaultUser: String {
        loadBundledMarkdown("DefaultUSER") ?? """
        # User Profile

        ## Name
        (Unknown)

        ## Preferences
        - Language: Auto-detect
        - Detail level: Balanced
        """
    }

    private static func loadBundledMarkdown(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
