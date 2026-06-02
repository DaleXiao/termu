import Darwin
import Combine
import Foundation

@MainActor
protocol PTYSessionTerminalRenderer: AnyObject {
    func resetTerminal(initialText: String)
    func feedTerminalData(_ data: Data)
}

@MainActor
final class PTYSession: ObservableObject {
    private struct TerminalSize: Equatable {
        let cols: Int
        let rows: Int
    }

    private struct LaunchConfiguration {
        let path: String
        let arguments: [String]
        let processName: String?
        let environment: [String: String]
        let currentDirectory: String?
    }

    enum State: Equatable {
        case idle
        case connecting
        case running
        case disconnected
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                return "Ready"
            case .connecting:
                return "Connecting"
            case .running:
                return "Connected"
            case .disconnected:
                return "Disconnected"
            case .failed:
                return "Failed"
            }
        }
    }

    enum PasswordFillStatus: Equatable {
        case none
        case waiting
        case sent
        case manual

        var title: String {
            switch self {
            case .none:
                return "No Saved Password"
            case .waiting:
                return "Password Ready"
            case .sent:
                return "Password Sent"
            case .manual:
                return "Password Needed"
            }
        }
    }

    private(set) var output = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var passwordFillStatus: PasswordFillStatus = .none
    @Published private(set) var hostID: HostRecord.ID?

    private weak var terminalRenderer: PTYSessionTerminalRenderer?
    private var terminalInitialText = ""
    private let outputLimit = 300_000
    private let terminalReplayLimit = 1_000_000
    private var terminalReplayBuffer = Data()
    private var masterFileHandle: FileHandle?
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var hasCompleted = false
    private var savedPassword = ""
    private var sentSavedPassword = false
    private var pendingTerminalAuthText = ""
    private var promptBuffer = ""
    private var passwordPromptWarningShown = false
    private var pendingFailureMessage: String?
    private var shouldTrimInitialTerminalLineBreaks = false
    private var initialTerminalPrefixBuffer = Data()
    private var terminalSize: TerminalSize?
    private var pendingLaunch: LaunchConfiguration?

    var isRunning: Bool {
        state == .connecting || state == .running
    }

    func attachTerminalRenderer(_ renderer: PTYSessionTerminalRenderer, initialText: String) {
        terminalRenderer = renderer
        renderer.resetTerminal(initialText: terminalInitialText.isEmpty ? initialText : terminalInitialText)
        if !terminalReplayBuffer.isEmpty {
            renderer.feedTerminalData(terminalReplayBuffer)
        }
    }

    func detachTerminalRenderer(_ renderer: PTYSessionTerminalRenderer) {
        if terminalRenderer === renderer {
            terminalRenderer = nil
        }
    }

    func prepare(host: HostRecord) {
        guard !isRunning else { return }

        let hasSavedPassword = host.kind == .ssh && !host.password.trimmingCharacters(in: .newlines).isEmpty
        passwordFillStatus = hasSavedPassword ? .waiting : .none

        guard hostID != host.id else { return }

        output = ""
        state = .idle
        savedPassword = ""
        sentSavedPassword = false
        pendingTerminalAuthText = ""
        promptBuffer = ""
        passwordPromptWarningShown = false
        pendingFailureMessage = nil
        shouldTrimInitialTerminalLineBreaks = false
        initialTerminalPrefixBuffer.removeAll()
        pendingLaunch = nil
        hostID = host.id
        resetTerminal(initialText: "")
    }

    func start(host: HostRecord) {
        guard host.isConnectable else { return }

        stop(appendMessage: false)
        output = ""
        resetTerminal(initialText: "")
        hasCompleted = false
        hostID = host.id
        savedPassword = host.kind == .ssh ? host.password.trimmingCharacters(in: .newlines) : ""
        sentSavedPassword = false
        pendingTerminalAuthText = ""
        promptBuffer = ""
        passwordPromptWarningShown = false
        pendingFailureMessage = nil
        shouldTrimInitialTerminalLineBreaks = true
        initialTerminalPrefixBuffer.removeAll()
        terminalSize = nil
        passwordFillStatus = savedPassword.isEmpty ? .none : .waiting
        state = .connecting

        let launchConfiguration: LaunchConfiguration
        switch host.kind {
        case .ssh:
            launchConfiguration = LaunchConfiguration(
                path: "/usr/bin/ssh",
                arguments: host.sshArguments(automatingSavedPassword: !savedPassword.isEmpty),
                processName: nil,
                environment: [:],
                currentDirectory: nil
            )
        case .local:
            let shellName = (host.localShellPath as NSString).lastPathComponent
            launchConfiguration = LaunchConfiguration(
                path: host.localShellPath,
                arguments: [],
                processName: "-\(shellName)",
                environment: Self.localTerminalEnvironment,
                currentDirectory: host.localWorkingDirectoryPath
            )
        }

        if let terminalSize {
            launch(launchConfiguration, terminalSize: terminalSize)
        } else {
            pendingLaunch = launchConfiguration
        }
    }

    func stop(appendMessage: Bool = true) {
        let hadPendingLaunch = pendingLaunch != nil
        let hadChild = childPID > 0

        guard hadPendingLaunch || hadChild || masterFileHandle != nil else { return }

        hasCompleted = true
        pendingLaunch = nil

        if childPID > 0 {
            Darwin.kill(childPID, SIGHUP)
        }

        cleanupProcess()

        if appendMessage, hadChild {
            output = ""
            resetTerminal(initialText: "")
        }

        if hadPendingLaunch || hadChild {
            state = .disconnected
        }
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        writeToPTY(data)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        writeToPTY(Data(bytes))
    }

    func resize(cols: Int, rows: Int) {
        let newTerminalSize = TerminalSize(cols: max(cols, 1), rows: max(rows, 1))

        if let pendingLaunch {
            terminalSize = newTerminalSize
            self.pendingLaunch = nil
            launch(pendingLaunch, terminalSize: newTerminalSize)
            return
        }

        guard terminalSize != newTerminalSize else { return }
        terminalSize = newTerminalSize

        guard masterFD >= 0 else { return }

        var windowSize = winsize(
            ws_row: UInt16(newTerminalSize.rows),
            ws_col: UInt16(newTerminalSize.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = Darwin.ioctl(masterFD, TIOCSWINSZ, &windowSize)
        signalWindowSizeChanged()
    }

    private func signalWindowSizeChanged() {
        guard childPID > 0 else { return }

        let foregroundProcessGroup = tcgetpgrp(masterFD)
        if foregroundProcessGroup > 0, foregroundProcessGroup != Darwin.getpgrp() {
            _ = Darwin.kill(-foregroundProcessGroup, SIGWINCH)
        } else {
            _ = Darwin.kill(childPID, SIGWINCH)
        }
    }

    private func writeToPTY(_ data: Data) {
        guard masterFD >= 0 else { return }
        let fd = masterFD

        DispatchQueue.global(qos: .userInitiated).async {
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }

                var bytesWritten = 0
                while bytesWritten < buffer.count {
                    let pointer = baseAddress.advanced(by: bytesWritten)
                    let result = Darwin.write(fd, pointer, buffer.count - bytesWritten)

                    if result <= 0 {
                        break
                    }

                    bytesWritten += result
                }
            }
        }
    }

    private func launch(_ configuration: LaunchConfiguration, terminalSize: TerminalSize) {
        state = .connecting

        var windowSize = winsize(
            ws_row: UInt16(terminalSize.rows),
            ws_col: UInt16(terminalSize.cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        var fileDescriptor: Int32 = -1
        let command = [configuration.processName ?? configuration.path] + configuration.arguments
        var cArguments = command.map { strdup($0) }
        cArguments.append(nil)

        let pid = forkpty(&fileDescriptor, nil, nil, &windowSize)

        if pid == 0 {
            unsetenv("NO_COLOR")
            setenv("TERM", "xterm-256color", 1)
            setenv("LC_CTYPE", "UTF-8", 1)
            configuration.environment.forEach { key, value in
                setenv(key, value, 1)
            }
            if let currentDirectory = configuration.currentDirectory {
                _ = currentDirectory.withCString { directoryPointer in
                    Darwin.chdir(directoryPointer)
                }
            }

            _ = configuration.path.withCString { pathPointer in
                cArguments.withUnsafeMutableBufferPointer { buffer in
                    execv(pathPointer, buffer.baseAddress)
                }
            }

            _exit(127)
        }

        for pointer in cArguments where pointer != nil {
            free(pointer)
        }

        guard pid > 0 else {
            state = .failed(Self.posixErrorDescription())
            return
        }

        masterFD = fileDescriptor
        childPID = pid
        state = .running

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        masterFileHandle = handle

        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData

            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning, !self.hasCompleted else { return }

                guard !data.isEmpty else {
                    self.finishSession()
                    return
                }

                let wasAwaitingSavedPasswordPrompt = !self.savedPassword.isEmpty && !self.sentSavedPassword
                let visibleText = Self.visibleText(from: data)
                let displayText = self.prepareDisplayText(from: visibleText)
                let terminalData = self.terminalDisplayData(
                    rawData: data,
                    visibleText: visibleText,
                    displayText: displayText,
                    wasAwaitingSavedPasswordPrompt: wasAwaitingSavedPasswordPrompt
                )
                self.feedTerminalData(self.trimInitialTerminalLineBreaks(from: terminalData))
                self.append(displayText)
                self.handleAuthenticationFailure(in: visibleText)
            }
        }
    }

    private func trimInitialTerminalLineBreaks(from data: Data) -> Data {
        guard shouldTrimInitialTerminalLineBreaks else { return data }

        initialTerminalPrefixBuffer.append(data)
        let trimmedData = Self.trimmingLeadingLineBreaksPreservingTerminalControls(from: initialTerminalPrefixBuffer)
        let visibleText = Self.visibleText(from: trimmedData)
        if visibleText.unicodeScalars.contains(where: { $0.value != 0x0A && $0.value != 0x0D }) {
            shouldTrimInitialTerminalLineBreaks = false
            initialTerminalPrefixBuffer.removeAll()
        } else {
            return Data()
        }

        return trimmedData
    }

    private func finishSession() {
        guard !hasCompleted else { return }

        hasCompleted = true
        cleanupProcess()
        if let pendingFailureMessage {
            state = .failed(pendingFailureMessage)
        } else {
            state = .disconnected
        }
    }

    private func cleanupProcess() {
        if let masterFileHandle {
            masterFileHandle.readabilityHandler = nil
            try? masterFileHandle.close()
        }

        masterFileHandle = nil
        masterFD = -1

        if childPID > 0 {
            var status: Int32 = 0
            waitpid(childPID, &status, WNOHANG)
            childPID = -1
        }
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }

        appendTerminalText(redacted(text))

        if !savedPassword.isEmpty {
            output = output.replacingOccurrences(of: savedPassword, with: "[password hidden]")
        }

        if output.count > outputLimit {
            output.removeFirst(output.count - outputLimit)
        }
    }

    private func appendSystemMessage(_ text: String) {
        append(text)
        feedTerminalText(text)
    }

    private func appendTerminalText(_ text: String) {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x7F:
                if !output.isEmpty {
                    output.removeLast()
                }
            default:
                output.unicodeScalars.append(scalar)
            }
        }
    }

    private func redacted(_ text: String) -> String {
        guard !savedPassword.isEmpty else { return text }
        return text.replacingOccurrences(of: savedPassword, with: "[password hidden]")
    }

    private func redactedTerminalData(_ data: Data) -> Data {
        guard !savedPassword.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return data
        }

        let redactedText = redacted(text)
        return redactedText.data(using: .utf8) ?? data
    }

    private func terminalDisplayData(
        rawData: Data,
        visibleText: String,
        displayText: String,
        wasAwaitingSavedPasswordPrompt: Bool
    ) -> Data {
        guard wasAwaitingSavedPasswordPrompt else {
            return rawData
        }

        pendingTerminalAuthText.append(visibleText)

        if displayText != visibleText || sentSavedPassword {
            let visibleText = Self.removingPasswordPromptLines(from: pendingTerminalAuthText)
            pendingTerminalAuthText = ""
            return visibleText.data(using: .utf8) ?? Data()
        }

        guard let lastLineBreak = pendingTerminalAuthText.lastIndex(of: "\n") else {
            return Data()
        }

        let afterLastLineBreak = pendingTerminalAuthText.index(after: lastLineBreak)
        let completeText = String(pendingTerminalAuthText[..<afterLastLineBreak])
        pendingTerminalAuthText = String(pendingTerminalAuthText[afterLastLineBreak...])

        let visibleText = Self.removingPasswordPromptLines(from: completeText)
        return visibleText.data(using: .utf8) ?? Data()
    }

    private func resetTerminal(initialText: String) {
        terminalInitialText = initialText
        terminalReplayBuffer.removeAll()
        terminalRenderer?.resetTerminal(initialText: initialText)
    }

    private func feedTerminalData(_ data: Data) {
        guard !data.isEmpty else { return }

        let displayData = redactedTerminalData(data)
        guard !displayData.isEmpty else { return }

        appendTerminalReplayData(displayData)
        terminalRenderer?.feedTerminalData(displayData)
    }

    private func feedTerminalText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        appendTerminalReplayData(data)
        terminalRenderer?.feedTerminalData(data)
    }

    private func appendTerminalReplayData(_ data: Data) {
        terminalReplayBuffer.append(data)

        if terminalReplayBuffer.count > terminalReplayLimit {
            terminalReplayBuffer.removeFirst(terminalReplayBuffer.count - terminalReplayLimit)
        }
    }

    private func prepareDisplayText(from text: String) -> String {
        promptBuffer.append(text)
        if promptBuffer.count > 1_000 {
            promptBuffer.removeFirst(promptBuffer.count - 1_000)
        }

        guard Self.containsPasswordPrompt(promptBuffer) else { return text }

        guard !savedPassword.isEmpty else {
            passwordFillStatus = .manual
            return text
        }

        let promptHiddenText = Self.removingPasswordPromptLines(from: text)
        output = Self.removingPasswordPromptLines(from: output)

        guard !sentSavedPassword else { return promptHiddenText }

        sentSavedPassword = true
        passwordFillStatus = .sent
        send(savedPassword + "\r")
        return promptHiddenText
    }

    private func handleAuthenticationFailure(in text: String) {
        guard pendingFailureMessage == nil else { return }
        guard Self.containsAuthenticationFailure(text) else { return }

        if savedPassword.isEmpty {
            pendingFailureMessage = "Permission denied"
            passwordFillStatus = .manual
        } else if sentSavedPassword {
            pendingFailureMessage = "Permission denied: saved password rejected"
            passwordFillStatus = .sent
            appendSystemMessage("\n[termu submitted the saved password, but the server rejected it. Update the saved password in the sidebar.]\n")
        } else {
            pendingFailureMessage = "Permission denied: no safe password prompt was available"
            passwordFillStatus = .manual
            appendSystemMessage("\n[termu could not find a safe password prompt before the server rejected the login.]\n")
        }
    }

    private static func containsPasswordPrompt(_ text: String) -> Bool {
        guard !containsAuthenticationFailure(text) else { return false }

        return text.components(separatedBy: .newlines).suffix(4).contains(where: isPasswordPromptLine)
    }

    private static func isPasswordPromptLine(_ line: String) -> Bool {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard prompt.hasSuffix(":") || prompt.hasSuffix("：") else { return false }

        return prompt.contains("password")
            || prompt.contains("密码")
            || prompt.contains("口令")
            || prompt.contains("passphrase for key")
            || prompt.hasPrefix("enter passphrase")
    }

    private static func removingPasswordPromptLines(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var removedLastLine = false
        let filteredLines = lines.enumerated().compactMap { index, line -> String? in
            guard isPasswordPromptLine(line) else { return line }
            removedLastLine = index == lines.count - 1
            return nil
        }

        var filteredText = filteredLines.joined(separator: "\n")
        if removedLastLine, !text.hasSuffix("\n"), !filteredText.isEmpty {
            filteredText.append("\n")
        }

        return filteredText
    }

    private static func containsAuthenticationFailure(_ text: String) -> Bool {
        text.lowercased().contains("permission denied")
    }

    private static func visibleText(from data: Data) -> String {
        let decoded = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var result = String.UnicodeScalarView()
        var escapeState = EscapeState.normal

        for scalar in decoded.unicodeScalars {
            switch escapeState {
            case .normal:
                switch scalar.value {
                case 0x1B:
                    escapeState = .escape
                case 0x08:
                    result.append(scalar)
                case 0x09, 0x0A:
                    result.append(scalar)
                case 0x7F:
                    result.append(scalar)
                case 0x00..<0x20:
                    continue
                default:
                    result.append(scalar)
                }
            case .escape:
                switch scalar.value {
                case 0x5B:
                    escapeState = .controlSequence
                case 0x5D:
                    escapeState = .operatingSystemCommand
                case 0x20...0x2F:
                    escapeState = .escapeIntermediate
                case 0x30...0x7E:
                    escapeState = .normal
                default:
                    escapeState = .normal
                }
            case .escapeIntermediate:
                if scalar.value >= 0x30 && scalar.value <= 0x7E {
                    escapeState = .normal
                } else if scalar.value < 0x20 || scalar.value > 0x2F {
                    escapeState = .normal
                }
            case .controlSequence:
                if scalar.value >= 0x40 && scalar.value <= 0x7E {
                    escapeState = .normal
                }
            case .operatingSystemCommand:
                if scalar.value == 0x07 {
                    escapeState = .normal
                } else if scalar.value == 0x1B {
                    escapeState = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                escapeState = scalar.value == 0x5C ? .normal : .operatingSystemCommand
            }
        }

        return String(result)
    }

    private static func trimmingLeadingLineBreaksPreservingTerminalControls(from data: Data) -> Data {
        var index = data.startIndex
        var controlPrefix = Data()
        var pendingBlankLineBytes = Data()
        var removedLineBreak = false

        while index < data.endIndex {
            let byte = data[index]

            if byte == 0x0A || byte == 0x0D {
                removedLineBreak = true
                pendingBlankLineBytes.removeAll()
                index = data.index(after: index)
                continue
            }

            if byte == 0x1B,
               let controlEndIndex = terminalControlEndIndex(in: data, from: index) {
                controlPrefix.append(contentsOf: data[index..<controlEndIndex])
                index = controlEndIndex
                continue
            }

            if isBlankLinePrefixByte(byte) {
                pendingBlankLineBytes.append(byte)
                index = data.index(after: index)
                continue
            }

            break
        }

        guard removedLineBreak else { return data }

        var trimmedData = controlPrefix
        trimmedData.append(pendingBlankLineBytes)
        trimmedData.append(contentsOf: data[index..<data.endIndex])
        return trimmedData
    }

    private static func isBlankLinePrefixByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00..<0x09, 0x0B..<0x1B, 0x20:
            return true
        default:
            return false
        }
    }

    private static func terminalControlEndIndex(in data: Data, from escapeIndex: Data.Index) -> Data.Index? {
        let firstIndex = data.index(after: escapeIndex)
        guard firstIndex < data.endIndex else { return nil }

        switch data[firstIndex] {
        case 0x5B:
            var index = data.index(after: firstIndex)
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte >= 0x40 && byte <= 0x7E {
                    return index
                }
            }
            return nil
        case 0x5D:
            var index = data.index(after: firstIndex)
            while index < data.endIndex {
                let byte = data[index]

                if byte == 0x07 {
                    return data.index(after: index)
                }

                if byte == 0x1B {
                    let nextIndex = data.index(after: index)
                    if nextIndex < data.endIndex, data[nextIndex] == 0x5C {
                        return data.index(after: nextIndex)
                    }
                }

                index = data.index(after: index)
            }
            return nil
        default:
            var index = firstIndex
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte >= 0x30 && byte <= 0x7E {
                    return index
                }
                if byte < 0x20 || byte > 0x2F {
                    return index
                }
            }
            return nil
        }
    }

    private enum EscapeState {
        case normal
        case escape
        case escapeIntermediate
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
    }

    private static var localTerminalEnvironment: [String: String] {
        let parentEnvironment = ProcessInfo.processInfo.environment
        let lang = nonEmptyEnvironmentValue("LANG", in: parentEnvironment) ?? "en_US.UTF-8"
        let lcCType = nonEmptyEnvironmentValue("LC_CTYPE", in: parentEnvironment) ?? lang

        return [
            "TERM_PROGRAM": "termu",
            "COLORTERM": "truecolor",
            "LANG": lang,
            "LC_CTYPE": lcCType,
            "PROMPT_EOL_MARK": ""
        ]
    }

    private static func nonEmptyEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func posixErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}
