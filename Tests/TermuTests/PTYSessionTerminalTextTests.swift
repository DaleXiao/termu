import Foundation
@testable import Termu
import XCTest

final class PTYSessionTerminalTextTests: XCTestCase {
    func testVisibleTextStripsTerminalControlSequences() {
        let data = Data("hello\u{001B}[31m red\u{001B}[0m\r\n\u{001B}]0;title\u{0007}done".utf8)

        XCTAssertEqual(PTYSession.visibleText(from: data), "hello red\ndone")
    }

    func testVisibleTextKeepsBackspaceAndDeleteForOutputEditing() {
        let data = Data("abc\u{0008}d\u{007F}".utf8)

        XCTAssertEqual(PTYSession.visibleText(from: data), "abc\u{0008}d\u{007F}")
    }

    func testRemovingPasswordPromptLinesHandlesEnglishAndChinesePrompts() {
        let text = "login\nalice@example.com's password:\n密码：\nready\n"

        XCTAssertEqual(PTYSession.removingPasswordPromptLines(from: text), "login\nready\n")
    }

    func testContainsPasswordPromptIgnoresAuthenticationFailure() {
        let text = "Permission denied, please try again.\npassword:"

        XCTAssertFalse(PTYSession.containsPasswordPrompt(text))
    }

    func testTrimmingLeadingLineBreaksPreservesTerminalControls() {
        let data = Data("\u{001B}[?2004h\r\n  prompt".utf8)
        let trimmed = PTYSession.trimmingLeadingLineBreaksPreservingTerminalControls(from: data)

        XCTAssertEqual(String(decoding: trimmed, as: UTF8.self), "\u{001B}[?2004h  prompt")
    }

    func testTrimmingLeadingLineBreaksLeavesNonBlankOutputUnchanged() {
        let data = Data("prompt\n".utf8)

        XCTAssertEqual(PTYSession.trimmingLeadingLineBreaksPreservingTerminalControls(from: data), data)
    }

    func testAIActivityMatcherRecognizesKnownCommandNames() {
        XCTAssertTrue(PTYSession.isKnownAIActivityProcess(
            processName: "claude",
            executablePath: "/opt/homebrew/bin/claude",
            arguments: ["claude"]
        ))
        XCTAssertTrue(PTYSession.isKnownAIActivityProcess(
            processName: "codex",
            executablePath: "/Users/example/.local/bin/codex",
            arguments: ["codex"]
        ))
    }

    func testAIActivityMatcherRecognizesNodeWrappedClaudeCode() {
        XCTAssertTrue(PTYSession.isKnownAIActivityProcess(
            processName: "node",
            executablePath: "/opt/homebrew/bin/node",
            arguments: [
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"
            ]
        ))
    }

    func testAIActivityMatcherIgnoresOrdinaryShellAndNodeProcesses() {
        XCTAssertFalse(PTYSession.isKnownAIActivityProcess(
            processName: "zsh",
            executablePath: "/bin/zsh",
            arguments: ["-zsh"]
        ))
        XCTAssertFalse(PTYSession.isKnownAIActivityProcess(
            processName: "node",
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["node", "/Users/example/project/server.js"]
        ))
    }

    func testAIThinkingIndicatorRecognizesClaudeStatusLine() {
        XCTAssertTrue(PTYSession.containsAIThinkingIndicator(in: "✻ Thinking…"))
        XCTAssertTrue(PTYSession.containsAIThinkingIndicator(in: "Thinking for 3s"))
    }

    func testAIThinkingIndicatorIgnoresOrdinaryOutput() {
        XCTAssertFalse(PTYSession.containsAIThinkingIndicator(in: "Welcome to Claude Code"))
        XCTAssertFalse(PTYSession.containsAIThinkingIndicator(in: "I think this should be a normal answer."))
    }
}
