import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum HostFilter: Hashable {
    case all
    case group(String)

    var title: String {
        switch self {
        case .all:
            return "All Hosts"
        case .group(let group):
            return group
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @StateObject private var sshSessions = SSHSessionStore()
    @StateObject private var localWorkspaces = LocalTerminalWorkspaceStore()
    @State private var filter: HostFilter = .all
    @State private var searchText = ""
    @State private var editingHostID: HostRecord.ID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var lastSidebarDividerDragAt = Date.distantPast

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HostSidebarView(
                filter: $filter,
                searchText: $searchText,
                editingHostID: $editingHostID,
                isRunning: isRunning,
                connect: connect,
                disconnect: disconnect,
                delete: delete
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
            .background(
                SidebarSplitViewWidthLimiter(minWidth: 260, maxWidth: 420) {
                    lastSidebarDividerDragAt = Date()
                }
            )
        } detail: {
            DetailView(
                sshSessions: sshSessions,
                localWorkspaces: localWorkspaces,
                connect: connect,
                newLocalTab: newLocalTab
            )
        }
        .onAppear(perform: prepareSelectedHost)
        .onChange(of: store.selectedHostID) { _, _ in
            prepareSelectedHost()
            if editingHostID != store.selectedHostID {
                editingHostID = nil
            }
        }
        .onChange(of: columnVisibility) { _, visibility in
            guard visibility != .all else { return }
            guard Date().timeIntervalSince(lastSidebarDividerDragAt) < 0.5 else { return }

            DispatchQueue.main.async {
                columnVisibility = .all
            }
        }
    }

    private func prepareSelectedHost() {
        guard let host = store.selectedHost else { return }
        switch host.kind {
        case .ssh:
            sshSessions.prepare(host: host)
        case .local:
            localWorkspaces.ensureWorkspace(for: host)
        }
    }

    private func connect(_ host: HostRecord) {
        guard host.isConnectable else { return }
        store.selectHost(host.id)

        switch host.kind {
        case .ssh:
            sshSessions.start(host: host)
        case .local:
            localWorkspaces.startSelectedTab(for: host)
        }

        store.markHostConnected(host.id)
    }

    private func newLocalTab(_ host: HostRecord) {
        guard host.kind == .local else { return }
        store.selectHost(host.id)
        localWorkspaces.newTab(for: host, start: true)
        store.markHostConnected(host.id)
    }

    private func disconnect(_ host: HostRecord) {
        switch host.kind {
        case .ssh:
            guard !sshSessions.isHostRunning(host.id) || shouldDisconnectSSHHost(host) else { return }
            sshSessions.stop(hostID: host.id)
        case .local:
            localWorkspaces.stopSelectedTab(for: host.id)
        }
    }

    private func shouldDisconnectSSHHost(_ host: HostRecord) -> Bool {
        guard store.configuration.confirmBeforeDisconnectingSSHHost else { return true }

        let alert = NSAlert()
        alert.messageText = "Disconnect SSH Host?"
        alert.informativeText = "This will disconnect \(host.title)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            store.setConfirmBeforeDisconnectingSSHHost(false)
        }
        return confirmed
    }

    private func delete(_ host: HostRecord) {
        switch host.kind {
        case .ssh:
            sshSessions.closeSession(for: host.id)
        case .local:
            localWorkspaces.closeWorkspace(for: host.id)
        }

        if editingHostID == host.id {
            editingHostID = nil
        }

        store.deleteHost(host.id)
        prepareSelectedHost()
    }

    private func isRunning(_ host: HostRecord) -> Bool {
        switch host.kind {
        case .ssh:
            return sshSessions.isHostRunning(host.id)
        case .local:
            return localWorkspaces.isHostRunning(host.id)
        }
    }
}

private struct HostSidebarView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @Binding var filter: HostFilter
    @Binding var searchText: String
    @Binding var editingHostID: HostRecord.ID?
    @State private var isShowingSettings = false
    @State private var draggingHostID: HostRecord.ID?
    @State private var lastMovedHostDropID: HostRecord.ID?
    @State private var didMoveHostToEnd = false
    let isRunning: (HostRecord) -> Bool
    let connect: (HostRecord) -> Void
    let disconnect: (HostRecord) -> Void
    let delete: (HostRecord) -> Void

    private var filteredHosts: [HostRecord] {
        store.hosts.filter { host in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .group(let group):
                matchesFilter = host.group == group
            }

            guard matchesFilter else { return false }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }

            return host.name.localizedCaseInsensitiveContains(query)
                || host.hostname.localizedCaseInsensitiveContains(query)
                || host.username.localizedCaseInsensitiveContains(query)
                || host.kind.title.localizedCaseInsensitiveContains(query)
                || host.localWorkingDirectory.localizedCaseInsensitiveContains(query)
                || host.tags.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarToolbar

            Divider()

            hostList
                .frame(minHeight: editingHostID == store.selectedHostID ? 160 : 220)

            if editingHostID == store.selectedHostID,
               let host = store.selectedHostBinding {
                Divider()

                SidebarEditorPanel(host: host) {
                    editingHostID = nil
                }
                .frame(minHeight: 320)
            }

            Divider()

            SidebarSettingsButton(isShowingSettings: $isShowingSettings)
                .padding(12)
        }
        .searchable(text: $searchText, placement: .sidebar)
    }

    private var sidebarToolbar: some View {
        HStack(spacing: 8) {
            Picker("Group", selection: $filter) {
                Label("All Hosts", systemImage: "server.rack")
                    .tag(HostFilter.all)

                ForEach(store.groups, id: \.self) { group in
                    Label(group, systemImage: "folder")
                        .tag(HostFilter.group(group))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Spacer(minLength: 8)

            Menu {
                Button {
                    store.addHost(kind: .ssh)
                    editingHostID = store.selectedHostID
                } label: {
                    Label("SSH Host", systemImage: "server.rack")
                }

                Button {
                    store.addHost(kind: .local)
                    editingHostID = store.selectedHostID
                } label: {
                    Label("Local", systemImage: "terminal")
                }
            } label: {
                Image(systemName: "plus")
            }
            .help("New Host")

            Button {
                if let host = store.selectedHost {
                    delete(host)
                }
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete Host")
            .disabled(store.selectedHost == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var hostList: some View {
        if filteredHosts.isEmpty {
            ContentUnavailableView(
                "No Hosts",
                systemImage: "server.rack",
                description: Text("Add a host to start building your terminal workspace.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Text(filter.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(filteredHosts) { host in
                        hostListRow(for: host)
                    }

                    Color.clear
                        .frame(height: 24)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [.text],
                            delegate: HostEndDropDelegate(
                                draggingHostID: $draggingHostID,
                                lastMovedHostDropID: $lastMovedHostDropID,
                                didMoveHostToEnd: $didMoveHostToEnd,
                                moveToEnd: { hostID in
                                    store.moveHostToEnd(hostID)
                                }
                            )
                        )
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func hostListRow(for host: HostRecord) -> some View {
        HostRow(
            host: host,
            isSelected: store.selectedHostID == host.id,
            isRunning: isRunning(host)
        )
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(store.selectedHostID == host.id ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectHost(host.id)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            connect(host)
        })
        .opacity(hostOpacity(for: host.id))
        .onDrag {
            dragItemProvider(for: host.id)
        }
        .onDrop(
            of: [.text],
            delegate: HostDropDelegate(
                targetHostID: host.id,
                draggingHostID: $draggingHostID,
                lastMovedHostDropID: $lastMovedHostDropID,
                didMoveHostToEnd: $didMoveHostToEnd,
                move: { sourceHostID, targetHostID in
                    store.moveHost(sourceHostID, to: targetHostID)
                }
            )
        )
        .contextMenu {
            HostContextMenu(
                host: host,
                isRunning: isRunning(host),
                connect: {
                    connect(host)
                },
                disconnect: {
                    disconnect(host)
                },
                edit: {
                    store.selectHost(host.id)
                    editingHostID = host.id
                },
                delete: {
                    delete(host)
                }
            )
        }
    }

    private func hostOpacity(for hostID: HostRecord.ID) -> Double {
        draggingHostID == hostID ? 0.55 : 1
    }

    private func dragItemProvider(for hostID: HostRecord.ID) -> NSItemProvider {
        draggingHostID = hostID
        return NSItemProvider(object: hostID.uuidString as NSString)
    }
}

private struct HostDropDelegate: DropDelegate {
    let targetHostID: HostRecord.ID
    @Binding var draggingHostID: HostRecord.ID?
    @Binding var lastMovedHostDropID: HostRecord.ID?
    @Binding var didMoveHostToEnd: Bool
    let move: (HostRecord.ID, HostRecord.ID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingHostID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggingHostID, draggingHostID != targetHostID else { return }
        move(draggingHostID, targetHostID)
        lastMovedHostDropID = targetHostID
        didMoveHostToEnd = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let didDrop = draggingHostID != nil
        if let draggingHostID,
           draggingHostID != targetHostID,
           lastMovedHostDropID != targetHostID {
            move(draggingHostID, targetHostID)
        }
        draggingHostID = nil
        lastMovedHostDropID = nil
        didMoveHostToEnd = false
        return didDrop
    }
}

private struct HostEndDropDelegate: DropDelegate {
    @Binding var draggingHostID: HostRecord.ID?
    @Binding var lastMovedHostDropID: HostRecord.ID?
    @Binding var didMoveHostToEnd: Bool
    let moveToEnd: (HostRecord.ID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingHostID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggingHostID else { return }
        moveToEnd(draggingHostID)
        lastMovedHostDropID = nil
        didMoveHostToEnd = true
    }

    func performDrop(info: DropInfo) -> Bool {
        let didDrop = draggingHostID != nil
        if let draggingHostID, !didMoveHostToEnd {
            moveToEnd(draggingHostID)
        }
        draggingHostID = nil
        lastMovedHostDropID = nil
        didMoveHostToEnd = false
        return didDrop
    }
}

private struct HostRow: View {
    let host: HostRecord
    let isSelected: Bool
    let isRunning: Bool

    var body: some View {
        HStack {
            Text(host.title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Image(systemName: isRunning ? "bolt.circle.fill" : host.isConnectable ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .primary : statusColor)
                .accessibilityLabel(isRunning ? "Connected" : host.isConnectable ? "Connectable" : "Incomplete")
        }
        .padding(.vertical, 7)
    }

    private var statusColor: Color {
        if isRunning {
            return .blue
        }

        return host.isConnectable ? .green : .secondary
    }
}

private struct HostContextMenu: View {
    @EnvironmentObject private var store: ConfigurationStore
    let host: HostRecord
    let isRunning: Bool
    let connect: () -> Void
    let disconnect: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        Button {
            edit()
        } label: {
            Label("Edit", systemImage: "slider.horizontal.3")
        }

        Button {
            connect()
        } label: {
            Label("Connect", systemImage: "bolt.fill")
        }
        .disabled(!host.isConnectable || isRunning)

        Button {
            disconnect()
        } label: {
            Label("Disconnect", systemImage: "xmark.circle")
        }
        .disabled(!isRunning)

        Divider()

        Button {
            store.connectInTerminal(host)
        } label: {
            Label("Open in Terminal", systemImage: "arrow.up.right.square")
        }
        .disabled(!host.isConnectable)

        if host.kind == .ssh {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(host.sshCommand, forType: .string)
            } label: {
                Label("Copy SSH Command", systemImage: "doc.on.doc")
            }
        }

        Divider()

        Button(role: .destructive) {
            delete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct SidebarEditorPanel: View {
    @Binding var host: HostRecord
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Edit Host", systemImage: "slider.horizontal.3")
                    .font(.headline)

                Spacer()

                Text(host.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close editor")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            HostEditorView(host: $host)
        }
    }
}

private struct DetailView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @ObservedObject var sshSessions: SSHSessionStore
    @ObservedObject var localWorkspaces: LocalTerminalWorkspaceStore
    let connect: (HostRecord) -> Void
    let newLocalTab: (HostRecord) -> Void

    var body: some View {
        if let host = store.selectedHostBinding {
            HostDetailView(
                host: host,
                sshSessions: sshSessions,
                localWorkspaces: localWorkspaces,
                onConnect: connect,
                onNewLocalTab: newLocalTab
            )
        } else {
            WorkspaceIdleView()
        }
    }
}

private struct SidebarSettingsButton: View {
    @EnvironmentObject private var store: ConfigurationStore
    @Binding var isShowingSettings: Bool

    var body: some View {
        Button {
            isShowingSettings.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text(store.cloudStatus.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Circle()
                    .fill(store.cloudStatus.color)
                    .frame(width: 8, height: 8)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowingSettings, arrowEdge: .bottom) {
            SettingsPanel()
                .environmentObject(store)
        }
    }
}

private struct SettingsPanel: View {
    @EnvironmentObject private var store: ConfigurationStore

    private var terminalTheme: Binding<TerminalTheme> {
        Binding(
            get: { store.configuration.terminalTheme },
            set: { store.setTerminalTheme($0) }
        )
    }

    private var confirmBeforeStoppingLocalTerminalTab: Binding<Bool> {
        Binding(
            get: { store.configuration.confirmBeforeStoppingLocalTerminalTab },
            set: { store.setConfirmBeforeStoppingLocalTerminalTab($0) }
        )
    }

    private var confirmBeforeClosingLocalTerminalTab: Binding<Bool> {
        Binding(
            get: { store.configuration.confirmBeforeClosingLocalTerminalTab },
            set: { store.setConfirmBeforeClosingLocalTerminalTab($0) }
        )
    }

    private var confirmBeforeDisconnectingSSHHost: Binding<Bool> {
        Binding(
            get: { store.configuration.confirmBeforeDisconnectingSSHHost },
            set: { store.setConfirmBeforeDisconnectingSSHHost($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Terminal Theme")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ThemeModeToggle(selection: terminalTheme)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Safety")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Toggle("Confirm before disconnecting SSH", isOn: confirmBeforeDisconnectingSSHHost)
                Toggle("Confirm before stopping a shell", isOn: confirmBeforeStoppingLocalTerminalTab)
                Toggle("Confirm before closing a tab", isOn: confirmBeforeClosingLocalTerminalTab)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("iCloud Sync")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 10) {
                    Circle()
                        .fill(store.cloudStatus.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.cloudStatus.title)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(store.cloudStatus.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Button {
                        store.refreshICloud()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh iCloud sync")
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct ThemeModeToggle: View {
    @Binding var selection: TerminalTheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(TerminalTheme.allCases) { theme in
                Button {
                    selection = theme
                } label: {
                    Image(systemName: theme.iconName)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(selection == theme ? .white : .secondary)
                        .background(
                            Circle()
                                .fill(selection == theme ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(theme.title)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .fixedSize()
    }
}

private extension TerminalTheme {
    var iconName: String {
        switch self {
        case .dark:
            return "moon.fill"
        case .light:
            return "sun.max.fill"
        case .system:
            return "circle.lefthalf.filled"
        }
    }
}

private extension CloudSyncStatus {
    var color: Color {
        switch self {
        case .synced:
            return .green
        case .syncing, .checking:
            return .blue
        case .unavailable:
            return .orange
        case .failed:
            return .red
        }
    }
}
