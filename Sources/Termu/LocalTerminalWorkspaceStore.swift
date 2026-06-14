import Combine
import Foundation

@MainActor
final class LocalTerminalTab: Identifiable {
    let id: UUID
    var title: String
    let session: PTYSession

    init(id: UUID = UUID(), title: String) {
        self.id = id
        self.title = title
        session = PTYSession()
    }
}

@MainActor
final class LocalTerminalWorkspaceStore: ObservableObject {
    private struct Workspace {
        var selectedTabID: LocalTerminalTab.ID
        var tabs: [LocalTerminalTab]
    }

    private struct PersistedState: Codable {
        var schemaVersion: Int = 1
        var workspaces: [PersistedWorkspace] = []
    }

    private struct PersistedWorkspace: Codable {
        var hostID: HostRecord.ID
        var selectedTabID: LocalTerminalTab.ID
        var tabs: [PersistedTab]
    }

    private struct PersistedTab: Codable {
        var id: LocalTerminalTab.ID
        var title: String
    }

    @Published private var workspaces: [HostRecord.ID: Workspace] = [:]

    private let localURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var persistedWorkspaces: [HostRecord.ID: PersistedWorkspace] = [:]
    private var sessionObservers: [LocalTerminalTab.ID: AnyCancellable] = [:]

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        localURL = applicationSupport
            .appendingPathComponent("termu", isDirectory: true)
            .appendingPathComponent("local-workspaces.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        loadPersistedWorkspaces()
    }

    func ensureWorkspace(for host: HostRecord) {
        guard host.kind == .local else { return }
        guard workspaces[host.id] == nil else { return }

        if let persistedWorkspace = persistedWorkspaces[host.id],
           let workspace = makeWorkspace(from: persistedWorkspace, host: host) {
            workspaces[host.id] = workspace
            return
        }

        let tab = makeTab(title: "Shell 1", host: host)
        let workspace = Workspace(selectedTabID: tab.id, tabs: [tab])
        workspaces[host.id] = workspace
        persist(workspace, for: host.id)
    }

    func tabs(for hostID: HostRecord.ID) -> [LocalTerminalTab] {
        workspaces[hostID]?.tabs ?? []
    }

    func selectedTab(for hostID: HostRecord.ID) -> LocalTerminalTab? {
        guard let workspace = workspaces[hostID] else { return nil }
        return workspace.tabs.first { $0.id == workspace.selectedTabID }
    }

    func selectTab(_ tabID: LocalTerminalTab.ID, for hostID: HostRecord.ID) {
        guard var workspace = workspaces[hostID],
              workspace.selectedTabID != tabID,
              workspace.tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        workspace.selectedTabID = tabID
        workspaces[hostID] = workspace
        persist(workspace, for: hostID)
    }

    func startSelectedTab(for host: HostRecord) {
        guard host.kind == .local else { return }

        ensureWorkspace(for: host)

        guard let tab = selectedTab(for: host.id),
              !tab.session.isRunning else {
            return
        }

        tab.session.start(host: host)
    }

    func newTab(for host: HostRecord, start: Bool) {
        guard host.kind == .local else { return }

        ensureWorkspace(for: host)
        guard var workspace = workspaces[host.id] else { return }

        let tab = makeTab(title: "Shell \(workspace.tabs.count + 1)", host: host)
        workspace.tabs.append(tab)
        workspace.selectedTabID = tab.id
        workspaces[host.id] = workspace

        if start {
            tab.session.start(host: host)
        }

        persist(workspace, for: host.id)
    }

    func closeTab(_ tabID: LocalTerminalTab.ID, for host: HostRecord) {
        guard var workspace = workspaces[host.id],
              let index = workspace.tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let tab = workspace.tabs.remove(at: index)
        tab.session.stop()
        sessionObservers[tab.id] = nil

        if workspace.tabs.isEmpty {
            let replacement = makeTab(title: "Shell 1", host: host)
            workspace.tabs = [replacement]
            workspace.selectedTabID = replacement.id
        } else if workspace.selectedTabID == tabID {
            workspace.selectedTabID = workspace.tabs[min(index, workspace.tabs.count - 1)].id
        }

        workspaces[host.id] = workspace
        persist(workspace, for: host.id)
    }

    func renameTab(_ tabID: LocalTerminalTab.ID, for hostID: HostRecord.ID, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              let workspace = workspaces[hostID],
              let tab = workspace.tabs.first(where: { $0.id == tabID }),
              tab.title != trimmedTitle else {
            return
        }

        tab.title = trimmedTitle
        workspaces[hostID] = workspace
        persist(workspace, for: hostID)
    }

    func moveTab(_ tabID: LocalTerminalTab.ID, to targetTabID: LocalTerminalTab.ID, for hostID: HostRecord.ID) {
        guard tabID != targetTabID,
              var workspace = workspaces[hostID],
              let sourceIndex = workspace.tabs.firstIndex(where: { $0.id == tabID }),
              let targetIndex = workspace.tabs.firstIndex(where: { $0.id == targetTabID }) else {
            return
        }

        let insertionIndex = targetIndex
        guard insertionIndex != sourceIndex else { return }

        let tab = workspace.tabs.remove(at: sourceIndex)
        workspace.tabs.insert(tab, at: insertionIndex)
        workspaces[hostID] = workspace
        persist(workspace, for: hostID)
    }

    func moveTabToEnd(_ tabID: LocalTerminalTab.ID, for hostID: HostRecord.ID) {
        guard var workspace = workspaces[hostID],
              let sourceIndex = workspace.tabs.firstIndex(where: { $0.id == tabID }),
              sourceIndex != workspace.tabs.count - 1 else {
            return
        }

        let tab = workspace.tabs.remove(at: sourceIndex)
        workspace.tabs.append(tab)
        workspaces[hostID] = workspace
        persist(workspace, for: hostID)
    }

    func stopSelectedTab(for hostID: HostRecord.ID) {
        selectedTab(for: hostID)?.session.stop()
    }

    func closeWorkspace(for hostID: HostRecord.ID) {
        guard let workspace = workspaces.removeValue(forKey: hostID) else { return }

        workspace.tabs.forEach { tab in
            tab.session.stop()
            sessionObservers[tab.id] = nil
        }
        persistedWorkspaces[hostID] = nil
        savePersistedWorkspaces()
    }

    func isHostRunning(_ hostID: HostRecord.ID) -> Bool {
        workspaces[hostID]?.tabs.contains { $0.session.isRunning } ?? false
    }

    private func makeTab(id: UUID = UUID(), title: String, host: HostRecord) -> LocalTerminalTab {
        let tab = LocalTerminalTab(id: id, title: title)
        tab.session.prepare(host: host)
        observe(tab)
        return tab
    }

    private func observe(_ tab: LocalTerminalTab) {
        sessionObservers[tab.id] = tab.session.$state.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    private func makeWorkspace(from persistedWorkspace: PersistedWorkspace, host: HostRecord) -> Workspace? {
        var seenTabIDs = Set<LocalTerminalTab.ID>()
        let tabs = persistedWorkspace.tabs.compactMap { persistedTab -> LocalTerminalTab? in
            let title = persistedTab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  seenTabIDs.insert(persistedTab.id).inserted else {
                return nil
            }

            return makeTab(id: persistedTab.id, title: title, host: host)
        }

        guard let firstTab = tabs.first else { return nil }
        let selectedTabID = tabs.contains { $0.id == persistedWorkspace.selectedTabID }
            ? persistedWorkspace.selectedTabID
            : firstTab.id

        return Workspace(selectedTabID: selectedTabID, tabs: tabs)
    }

    private func persist(_ workspace: Workspace, for hostID: HostRecord.ID) {
        let persistedWorkspace = PersistedWorkspace(
            hostID: hostID,
            selectedTabID: workspace.selectedTabID,
            tabs: workspace.tabs.map { PersistedTab(id: $0.id, title: $0.title) }
        )
        persistedWorkspaces[hostID] = persistedWorkspace
        savePersistedWorkspaces()
    }

    private func loadPersistedWorkspaces() {
        do {
            let data = try Data(contentsOf: localURL)
            let state = try decoder.decode(PersistedState.self, from: data)
            persistedWorkspaces = state.workspaces.reduce(into: [:]) { result, workspace in
                result[workspace.hostID] = workspace
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            persistedWorkspaces = [:]
        } catch {
            persistedWorkspaces = [:]
        }
    }

    private func savePersistedWorkspaces() {
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let workspaces = persistedWorkspaces.values.sorted {
                $0.hostID.uuidString < $1.hostID.uuidString
            }
            let data = try encoder.encode(PersistedState(workspaces: workspaces))
            try data.write(to: localURL, options: .atomic)
        } catch {
        }
    }
}
