import Foundation
import SwiftUI

@MainActor
final class ConfigurationStore: ObservableObject {
    @Published private(set) var configuration = TermuConfiguration()
    @Published var selectedHostID: HostRecord.ID?
    @Published private(set) var cloudStatus: CloudSyncStatus = .checking

    private let cloudKey = "termu.configuration.v1"
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let localURL: URL
    private var cloudObserver: NSObjectProtocol?
    private var isApplyingRemoteConfiguration = false
    private var selectionSaveTask: Task<Void, Never>?

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        localURL = applicationSupport
            .appendingPathComponent("termu", isDirectory: true)
            .appendingPathComponent("config.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        loadLocalConfiguration()
        selectedHostID = configuration.selectedHostID ?? configuration.hosts.first?.id
        observeICloudChanges()
        pullFromICloud()
    }

    var hosts: [HostRecord] {
        configuration.hosts
    }

    var groups: [String] {
        Array(Set(configuration.hosts.map(\.group).filter { !$0.isEmpty })).sorted()
    }

    var selectedHost: HostRecord? {
        guard let selectedHostID else { return nil }
        return configuration.hosts.first { $0.id == selectedHostID }
    }

    func host(withID id: HostRecord.ID?) -> HostRecord? {
        guard let id else { return nil }
        return configuration.hosts.first { $0.id == id }
    }

    var selectedHostBinding: Binding<HostRecord>? {
        guard let selectedHostID,
              let index = configuration.hosts.firstIndex(where: { $0.id == selectedHostID }) else {
            return nil
        }

        return Binding(
            get: { self.configuration.hosts[index] },
            set: { newValue in
                self.configuration.hosts[index] = newValue
                self.markEdited()
            }
        )
    }

    func addHost(kind: HostKind = .ssh) {
        var host = HostRecord(kind: kind)
        if kind == .ssh, let firstGroup = groups.first {
            host.group = firstGroup
        }

        configuration.hosts.insert(host, at: 0)
        selectedHostID = host.id
        markEdited()
    }

    func deleteSelectedHost() {
        guard let selectedHostID else {
            return
        }

        deleteHost(selectedHostID)
    }

    func deleteHost(_ id: HostRecord.ID) {
        guard let index = configuration.hosts.firstIndex(where: { $0.id == id }) else {
            return
        }

        configuration.hosts.remove(at: index)

        if selectedHostID == id {
            let nextIndex = min(index, configuration.hosts.count - 1)
            selectedHostID = nextIndex >= 0 ? configuration.hosts[nextIndex].id : nil
        }

        markEdited()
    }

    func moveHost(_ id: HostRecord.ID, to targetID: HostRecord.ID) {
        guard id != targetID,
              let sourceIndex = configuration.hosts.firstIndex(where: { $0.id == id }),
              let targetIndex = configuration.hosts.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let insertionIndex = targetIndex
        guard insertionIndex != sourceIndex else { return }

        let host = configuration.hosts.remove(at: sourceIndex)
        configuration.hosts.insert(host, at: insertionIndex)
        markEdited()
    }

    func moveHostToEnd(_ id: HostRecord.ID) {
        guard let sourceIndex = configuration.hosts.firstIndex(where: { $0.id == id }),
              sourceIndex != configuration.hosts.count - 1 else {
            return
        }

        let host = configuration.hosts.remove(at: sourceIndex)
        configuration.hosts.append(host)
        markEdited()
    }

    func markHostConnected(_ id: HostRecord.ID) {
        guard let index = configuration.hosts.firstIndex(where: { $0.id == id }) else {
            return
        }

        configuration.hosts[index].lastConnectedAt = Date()
        markEdited()
    }

    func selectHost(_ id: HostRecord.ID?) {
        guard selectedHostID != id else { return }

        selectedHostID = id
        configuration.selectedHostID = id
        scheduleSelectedHostPersistence(id)
    }

    func refreshICloud() {
        pullFromICloud()
    }

    func setTerminalTheme(_ theme: TerminalTheme) {
        guard configuration.terminalTheme != theme else { return }

        configuration.terminalTheme = theme
        markEdited()
    }

    func setConfirmBeforeDisconnectingSSHHost(_ shouldConfirm: Bool) {
        guard configuration.confirmBeforeDisconnectingSSHHost != shouldConfirm else { return }

        configuration.confirmBeforeDisconnectingSSHHost = shouldConfirm
        markEdited()
    }

    func setConfirmBeforeStoppingLocalTerminalTab(_ shouldConfirm: Bool) {
        guard configuration.confirmBeforeStoppingLocalTerminalTab != shouldConfirm else { return }

        configuration.confirmBeforeStoppingLocalTerminalTab = shouldConfirm
        markEdited()
    }

    func setConfirmBeforeClosingLocalTerminalTab(_ shouldConfirm: Bool) {
        guard configuration.confirmBeforeClosingLocalTerminalTab != shouldConfirm else { return }

        configuration.confirmBeforeClosingLocalTerminalTab = shouldConfirm
        markEdited()
    }

    func connectSelectedHostInTerminal() {
        guard let selectedHost else { return }
        connectInTerminal(selectedHost)
    }

    func connectInTerminal(_ host: HostRecord) {
        guard host.isConnectable else { return }

        let command: String
        switch host.kind {
        case .ssh:
            command = host.sshCommand
        case .local:
            let shell = host.localShellPath.shellQuoted
            if let workingDirectory = host.localWorkingDirectoryPath {
                command = "cd \(workingDirectory.shellQuoted) && exec \(shell) -l"
            } else {
                command = "exec \(shell) -l"
            }
        }

        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            if let index = configuration.hosts.firstIndex(where: { $0.id == host.id }) {
                configuration.hosts[index].lastConnectedAt = Date()
                markEdited()
            }
        } catch {
            cloudStatus = .failed("Unable to open Terminal: \(error.localizedDescription)")
        }
    }

    private func markEdited(pushToCloud: Bool = true) {
        guard !isApplyingRemoteConfiguration else { return }

        configuration.selectedHostID = selectedHostID
        configuration.updatedAt = Date()
        saveLocalConfiguration()

        if pushToCloud {
            pushToICloud()
        }
    }

    private func scheduleSelectedHostPersistence(_ id: HostRecord.ID?) {
        selectionSaveTask?.cancel()
        selectionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.persistSelectedHostIfCurrent(id)
        }
    }

    private func persistSelectedHostIfCurrent(_ id: HostRecord.ID?) {
        guard !isApplyingRemoteConfiguration, selectedHostID == id else { return }

        configuration.selectedHostID = id
        saveLocalConfiguration()
    }

    private func loadLocalConfiguration() {
        do {
            let data = try Data(contentsOf: localURL)
            configuration = try decoder.decode(TermuConfiguration.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            configuration = TermuConfiguration()
            saveLocalConfiguration()
        } catch {
            configuration = TermuConfiguration()
            cloudStatus = .failed("Could not read local config: \(error.localizedDescription)")
        }
    }

    private func saveLocalConfiguration() {
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try encoder.encode(configuration)
            try data.write(to: localURL, options: .atomic)
        } catch {
            cloudStatus = .failed("Could not save local config: \(error.localizedDescription)")
        }
    }

    private func observeICloudChanges() {
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pullFromICloud()
            }
        }
    }

    private func pullFromICloud() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            cloudStatus = .unavailable
            return
        }

        cloudStatus = .syncing
        cloudStore.synchronize()

        guard let remoteString = cloudStore.string(forKey: cloudKey),
              let remoteData = Data(base64Encoded: remoteString) else {
            pushToICloud()
            return
        }

        do {
            let remoteConfiguration = try decoder.decode(TermuConfiguration.self, from: remoteData)
            if remoteConfiguration.updatedAt > configuration.updatedAt {
                isApplyingRemoteConfiguration = true
                configuration = remoteConfiguration
                selectedHostID = remoteConfiguration.selectedHostID ?? remoteConfiguration.hosts.first?.id
                saveLocalConfiguration()
                isApplyingRemoteConfiguration = false
            }
            cloudStatus = .synced(Date())
        } catch {
            cloudStatus = .failed("Could not read iCloud config: \(error.localizedDescription)")
        }
    }

    private func pushToICloud() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            cloudStatus = .unavailable
            return
        }

        do {
            cloudStatus = .syncing
            let data = try encoder.encode(configuration)
            cloudStore.set(data.base64EncodedString(), forKey: cloudKey)
            let accepted = cloudStore.synchronize()
            cloudStatus = accepted ? .synced(Date()) : .unavailable
        } catch {
            cloudStatus = .failed("Could not encode iCloud config: \(error.localizedDescription)")
        }
    }
}
