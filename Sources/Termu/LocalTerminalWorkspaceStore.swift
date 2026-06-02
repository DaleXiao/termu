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

    @Published private var workspaces: [HostRecord.ID: Workspace] = [:]

    private var sessionObservers: [LocalTerminalTab.ID: AnyCancellable] = [:]

    func ensureWorkspace(for host: HostRecord) {
        guard host.kind == .local else { return }
        guard workspaces[host.id] == nil else { return }

        let tab = makeTab(title: "Shell 1", host: host)
        workspaces[host.id] = Workspace(selectedTabID: tab.id, tabs: [tab])
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
    }

    func isHostRunning(_ hostID: HostRecord.ID) -> Bool {
        workspaces[hostID]?.tabs.contains { $0.session.isRunning } ?? false
    }

    private func makeTab(title: String, host: HostRecord) -> LocalTerminalTab {
        let tab = LocalTerminalTab(title: title)
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
}
