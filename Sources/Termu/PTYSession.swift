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
        let monitorsAIActivity: Bool
    }

    private struct ProcessIdentity {
        let name: String
        let executablePath: String?
        let arguments: [String]
    }

    private struct TerminalReplayBuffer {
        let limit: Int
        private var chunks: [Data] = []
        private var firstChunkIndex = 0
        private(set) var count = 0

        init(limit: Int) {
            self.limit = limit
        }

        var isEmpty: Bool {
            count == 0
        }

        var data: Data {
            var result = Data()
            result.reserveCapacity(count)
            for index in firstChunkIndex..<chunks.count {
                result.append(chunks[index])
            }
            return result
        }

        mutating func append(_ data: Data) {
            guard !data.isEmpty else { return }

            chunks.append(data)
            count += data.count
            trimToLimit()
        }

        mutating func removeAll() {
            chunks.removeAll(keepingCapacity: true)
            firstChunkIndex = 0
            count = 0
        }

        private mutating func trimToLimit() {
            var excess = count - limit
            guard excess > 0 else { return }

            while excess > 0, firstChunkIndex < chunks.count {
                let chunkCount = chunks[firstChunkIndex].count
                if chunkCount <= excess {
                    excess -= chunkCount
                    count -= chunkCount
                    firstChunkIndex += 1
                } else {
                    chunks[firstChunkIndex].removeFirst(excess)
                    count -= excess
                    excess = 0
                }
            }

            compactChunksIfNeeded()
        }

        private mutating func compactChunksIfNeeded() {
            guard firstChunkIndex > 32, firstChunkIndex * 2 > chunks.count else { return }

            chunks.removeFirst(firstChunkIndex)
            firstChunkIndex = 0
        }
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
    @Published private(set) var isAIActivityActive = false

    private weak var terminalRenderer: PTYSessionTerminalRenderer?
    private var terminalInitialText = ""
    private let outputLimit = 300_000
    private var terminalReplayBuffer = TerminalReplayBuffer(limit: 1_000_000)
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
    private var shouldAnchorInitialLocalPromptAtTop = false
    private var initialTerminalPrefixBuffer = Data()
    private var terminalSize: TerminalSize?
    private var pendingLaunch: LaunchConfiguration?
    private var aiActivityMonitor: DispatchSourceTimer?
    private var aiActivityDeactivation: DispatchWorkItem?
    private var supportsAIActivityMonitoring = false
    private var wantsAIActivityMonitoring = false
    private var hasKnownAIProcessForeground = false
    private var isAwaitingAIModelOutput = false
    private static let aiActivityOutputIdleDelay: TimeInterval = 1.1

    var isRunning: Bool {
        state == .connecting || state == .running
    }

    func attachTerminalRenderer(_ renderer: PTYSessionTerminalRenderer, initialText: String) {
        terminalRenderer = renderer
        renderer.resetTerminal(initialText: terminalInitialText.isEmpty ? initialText : terminalInitialText)
        if !terminalReplayBuffer.isEmpty {
            renderer.feedTerminalData(terminalReplayBuffer.data)
        }
    }

    func detachTerminalRenderer(_ renderer: PTYSessionTerminalRenderer) {
        if terminalRenderer === renderer {
            terminalRenderer = nil
        }
    }

    func setAIActivityMonitoringVisible(_ isVisible: Bool) {
        guard wantsAIActivityMonitoring != isVisible else { return }

        wantsAIActivityMonitoring = isVisible
        updateAIActivityMonitor()
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
        shouldAnchorInitialLocalPromptAtTop = false
        initialTerminalPrefixBuffer.removeAll()
        pendingLaunch = nil
        supportsAIActivityMonitoring = false
        hasKnownAIProcessForeground = false
        isAwaitingAIModelOutput = false
        cancelAIActivityDeactivation()
        setAIActivityActive(false)
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
        shouldAnchorInitialLocalPromptAtTop = host.kind == .local
        initialTerminalPrefixBuffer.removeAll()
        terminalSize = nil
        supportsAIActivityMonitoring = false
        hasKnownAIProcessForeground = false
        isAwaitingAIModelOutput = false
        cancelAIActivityDeactivation()
        setAIActivityActive(false)
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
                currentDirectory: nil,
                monitorsAIActivity: false
            )
        case .local:
            let shellName = (host.localShellPath as NSString).lastPathComponent
            launchConfiguration = LaunchConfiguration(
                path: host.localShellPath,
                arguments: [],
                processName: "-\(shellName)",
                environment: Self.localTerminalEnvironment,
                currentDirectory: host.localWorkingDirectoryPath,
                monitorsAIActivity: true
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
        shouldAnchorInitialLocalPromptAtTop = false

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
        shouldAnchorInitialLocalPromptAtTop = false
        recordTerminalInput(data)
        writeToPTY(data)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        let data = Data(bytes)
        shouldAnchorInitialLocalPromptAtTop = false
        recordTerminalInput(data)
        writeToPTY(data)
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
        supportsAIActivityMonitoring = configuration.monitorsAIActivity
        updateAIActivityMonitor()

        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        masterFileHandle = handle

        handle.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            let visibleText = data.isEmpty ? "" : Self.visibleText(from: data)

            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning, !self.hasCompleted else { return }

                guard !data.isEmpty else {
                    self.finishSession()
                    return
                }

                let wasAwaitingSavedPasswordPrompt = !self.savedPassword.isEmpty && !self.sentSavedPassword
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
                self.updateAIActivityState(from: visibleText)
            }
        }
    }

    private func trimInitialTerminalLineBreaks(from data: Data) -> Data {
        guard shouldTrimInitialTerminalLineBreaks else {
            return shouldAnchorInitialLocalPromptAtTop
                ? Self.trimmingLeadingLineBreaksPreservingTerminalControls(from: data)
                : data
        }

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
        stopAIActivityMonitor()

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
        hasKnownAIProcessForeground = false
        isAwaitingAIModelOutput = false
        cancelAIActivityDeactivation()
        supportsAIActivityMonitoring = false
    }

    private func updateAIActivityMonitor() {
        let shouldMonitor = supportsAIActivityMonitoring && wantsAIActivityMonitoring && isRunning
        if shouldMonitor {
            startAIActivityMonitorIfNeeded()
        } else {
            stopAIActivityMonitor()
        }
    }

    private func startAIActivityMonitorIfNeeded() {
        guard aiActivityMonitor == nil else { return }
        stopAIActivityMonitor()

        guard masterFD >= 0, childPID > 0 else { return }

        let monitoredFD = masterFD
        let monitoredChildPID = childPID
        let queue = DispatchQueue(
            label: "com.dingxiao.termu.ai-activity.\(monitoredChildPID)",
            qos: .utility
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1_200), leeway: .milliseconds(300))
        timer.setEventHandler(handler: Self.aiActivityMonitorHandler(
            masterFD: monitoredFD,
            childPID: monitoredChildPID,
            session: self
        ))

        aiActivityMonitor = timer
        timer.resume()
    }

    private func stopAIActivityMonitor() {
        aiActivityMonitor?.cancel()
        aiActivityMonitor = nil
        hasKnownAIProcessForeground = false
        isAwaitingAIModelOutput = false
        cancelAIActivityDeactivation()
        setAIActivityActive(false)
    }

    private func setAIActivityActive(_ isActive: Bool) {
        guard isAIActivityActive != isActive else { return }
        isAIActivityActive = isActive
    }

    nonisolated private static func aiActivityMonitorHandler(
        masterFD: Int32,
        childPID: pid_t,
        session: PTYSession
    ) -> () -> Void {
        {
            [weak session] in
            let hasKnownAIProcess = hasKnownAIProcessInForeground(masterFD: masterFD)

            Task { @MainActor in
                guard let session,
                      session.masterFD == masterFD,
                      session.childPID == childPID,
                      session.isRunning else {
                    return
                }

                session.setKnownAIProcessForeground(hasKnownAIProcess)
            }
        }
    }

    private func setKnownAIProcessForeground(_ isForeground: Bool) {
        hasKnownAIProcessForeground = isForeground
        if !isForeground {
            isAwaitingAIModelOutput = false
            cancelAIActivityDeactivation()
            setAIActivityActive(false)
        }
    }

    private func recordTerminalInput(_ data: Data) {
        guard supportsAIActivityMonitoring, hasKnownAIProcessForeground else { return }
        guard data.contains(0x0A) || data.contains(0x0D) else { return }

        isAwaitingAIModelOutput = true
        cancelAIActivityDeactivation()
        setAIActivityActive(false)
    }

    private func scheduleAIActivityDeactivationAfterOutputIdle() {
        aiActivityDeactivation?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.setAIActivityActive(false)
            self?.aiActivityDeactivation = nil
        }
        aiActivityDeactivation = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.aiActivityOutputIdleDelay,
            execute: workItem
        )
    }

    private func cancelAIActivityDeactivation() {
        aiActivityDeactivation?.cancel()
        aiActivityDeactivation = nil
    }

    private func updateAIActivityState(from visibleText: String) {
        guard supportsAIActivityMonitoring else { return }
        guard visibleText.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else { return }

        let containsAIStatus = Self.containsAIThinkingIndicator(in: visibleText)
        guard containsAIStatus || hasKnownAIProcessForeground else {
            isAwaitingAIModelOutput = false
            cancelAIActivityDeactivation()
            setAIActivityActive(false)
            return
        }

        if containsAIStatus || isAwaitingAIModelOutput || isAIActivityActive {
            isAwaitingAIModelOutput = false
            setAIActivityActive(true)
            scheduleAIActivityDeactivationAfterOutputIdle()
        }
    }

    nonisolated private static func hasKnownAIProcessInForeground(masterFD: Int32) -> Bool {
        let processGroupID = tcgetpgrp(masterFD)
        guard processGroupID > 0 else { return false }

        return processIdentities(inProcessGroup: processGroupID).contains { identity in
            isKnownAIActivityProcess(
                processName: identity.name,
                executablePath: identity.executablePath,
                arguments: identity.arguments
            )
        }
    }

    nonisolated private static func processIdentities(inProcessGroup processGroupID: pid_t) -> [ProcessIdentity] {
        let pidByteCount = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processGroupID), nil, 0)
        guard pidByteCount > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: Int(pidByteCount) / MemoryLayout<pid_t>.size)
        let actualByteCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(processGroupID),
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard actualByteCount > 0 else { return [] }

        return pids.prefix(Int(actualByteCount) / MemoryLayout<pid_t>.size).compactMap { pid in
            guard pid > 0 else { return nil }

            var info = proc_bsdinfo()
            let infoByteCount = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(
                    pid,
                    PROC_PIDTBSDINFO,
                    0,
                    pointer,
                    Int32(MemoryLayout<proc_bsdinfo>.size)
                )
            }
            guard infoByteCount == Int32(MemoryLayout<proc_bsdinfo>.size),
                  info.pbi_pgid == processGroupID else {
                return nil
            }

            return ProcessIdentity(
                name: processName(from: info),
                executablePath: executablePath(for: pid),
                arguments: commandArguments(for: pid)
            )
        }
    }

    nonisolated private static func processName(from info: proc_bsdinfo) -> String {
        var name = info.pbi_name
        return withUnsafeBytes(of: &name) { rawBuffer in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(bytes: bytes, encoding: .utf8) ?? ""
        }
    }

    nonisolated private static func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }

        guard pathLength > 0 else { return nil }
        let bytes = pathBuffer
            .prefix(min(Int(pathLength), pathBuffer.count))
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private static func commandArguments(for pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return []
        }

        return buffer
            .dropFirst(MemoryLayout<Int32>.size)
            .prefix(max(size - MemoryLayout<Int32>.size, 0))
            .split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(bytes: $0, encoding: .utf8) }
    }

    nonisolated static func isKnownAIActivityProcess(
        processName: String,
        executablePath: String?,
        arguments: [String]
    ) -> Bool {
        let identifiers = [processName, executablePath].compactMap { $0 } + arguments.prefix(2)
        return identifiers.contains(where: isKnownAICommandIdentifier)
    }

    nonisolated private static func isKnownAICommandIdentifier(_ identifier: String) -> Bool {
        let trimmedIdentifier = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        guard !trimmedIdentifier.isEmpty else { return false }

        let knownCommands: Set<String> = [
            "aider",
            "claude",
            "claude-code",
            "codex",
            "gemini",
            "opencode"
        ]
        let components = trimmedIdentifier
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .filter { !$0.isEmpty }
        let candidates = ([trimmedIdentifier] + components).flatMap { component in
            [component, strippingKnownExecutableExtension(from: component)]
        }

        return candidates.contains { knownCommands.contains($0) }
    }

    nonisolated private static func strippingKnownExecutableExtension(from value: String) -> String {
        for suffix in [".js", ".mjs", ".cjs"] where value.hasSuffix(suffix) {
            return String(value.dropLast(suffix.count))
        }

        return value
    }

    nonisolated static func containsAIThinkingIndicator(in text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let normalizedLine = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedLine.count <= 120 else { return false }
            if normalizedLine.contains("thinking") {
                return !normalizedLine.hasPrefix("i think")
                    && !normalizedLine.hasPrefix("i'm thinking")
                    && !normalizedLine.hasPrefix("i’m thinking")
            }

            let statusPrefixes = ["✻", "✽", "✶", "✢", "✳", "✹", "⏺"]
            return statusPrefixes.contains { normalizedLine.hasPrefix($0) }
        }
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }

        let redactedText = redacted(text)
        appendTerminalText(redactedText)
        redactOutputTail(appendedCharacterCount: redactedText.count)

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

    private func redactOutputTail(appendedCharacterCount: Int) {
        guard !savedPassword.isEmpty, !output.isEmpty else { return }

        let tailLength = min(output.count, max(savedPassword.count + appendedCharacterCount + 1, savedPassword.count))
        guard tailLength > 0 else { return }

        let tailStart = output.index(output.endIndex, offsetBy: -tailLength)
        let redactedTail = String(output[tailStart...])
            .replacingOccurrences(of: savedPassword, with: "[password hidden]")
        output.replaceSubrange(tailStart..., with: redactedTail)
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

    nonisolated static func containsPasswordPrompt(_ text: String) -> Bool {
        guard !containsAuthenticationFailure(text) else { return false }

        return text.components(separatedBy: .newlines).suffix(4).contains(where: isPasswordPromptLine)
    }

    nonisolated private static func isPasswordPromptLine(_ line: String) -> Bool {
        let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard prompt.hasSuffix(":") || prompt.hasSuffix("：") else { return false }

        return prompt.contains("password")
            || prompt.contains("密码")
            || prompt.contains("口令")
            || prompt.contains("passphrase for key")
            || prompt.hasPrefix("enter passphrase")
    }

    nonisolated static func removingPasswordPromptLines(from text: String) -> String {
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

    nonisolated private static func containsAuthenticationFailure(_ text: String) -> Bool {
        text.lowercased().contains("permission denied")
    }

    nonisolated static func visibleText(from data: Data) -> String {
        let decoded = String(decoding: data, as: UTF8.self)
        let lineFeed = UnicodeScalar(0x0A)!
        var result = String.UnicodeScalarView()
        var escapeState = EscapeState.normal
        var skipsNextLineFeed = false

        for decodedScalar in decoded.unicodeScalars {
            if skipsNextLineFeed {
                skipsNextLineFeed = false
                if decodedScalar.value == 0x0A {
                    continue
                }
            }

            let isCarriageReturn = decodedScalar.value == 0x0D
            let scalar = isCarriageReturn ? lineFeed : decodedScalar
            if isCarriageReturn {
                skipsNextLineFeed = true
            }

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

    nonisolated static func trimmingLeadingLineBreaksPreservingTerminalControls(from data: Data) -> Data {
        var index = data.startIndex
        var controlPrefix = Data()
        var pendingBlankLineBytes = Data()
        var removedLineBreak = false

        while index < data.endIndex {
            let byte = data[index]

            if byte == 0x0D {
                let nextIndex = data.index(after: index)
                if nextIndex < data.endIndex, data[nextIndex] == 0x0A {
                    removedLineBreak = true
                    pendingBlankLineBytes.removeAll()
                    index = data.index(after: nextIndex)
                } else {
                    controlPrefix.append(byte)
                    index = nextIndex
                }
                continue
            }

            if byte == 0x0A {
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

    nonisolated private static func isBlankLinePrefixByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00..<0x09, 0x0B..<0x1B, 0x20:
            return true
        default:
            return false
        }
    }

    nonisolated private static func terminalControlEndIndex(in data: Data, from escapeIndex: Data.Index) -> Data.Index? {
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
