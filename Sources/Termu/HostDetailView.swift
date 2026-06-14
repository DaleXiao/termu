import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HostDetailView: View {
    @Binding var host: HostRecord
    @ObservedObject var sshSessions: SSHSessionStore
    @ObservedObject var localWorkspaces: LocalTerminalWorkspaceStore
    let onConnect: (HostRecord) -> Void
    let onNewLocalTab: (HostRecord) -> Void

    var body: some View {
        switch host.kind {
        case .ssh:
            SessionView(host: $host, session: sshSessions.session(for: host), onConnect: onConnect)
        case .local:
            LocalTerminalWorkspaceView(
                host: $host,
                workspaces: localWorkspaces,
                onConnect: onConnect,
                onNewTab: onNewLocalTab
            )
        }
    }
}

private struct SessionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ConfigurationStore
    @Binding var host: HostRecord
    @ObservedObject var session: PTYSession
    let onConnect: (HostRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(host.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

                Button {
                    onConnect(host)
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!host.isConnectable || session.isRunning)

                Button {
                    disconnectSSHHost()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(session.isRunning ? .red : .gray)
                .disabled(!session.isRunning)

                Divider()
                    .frame(height: 18)

                Label(session.state.title, systemImage: statusIcon)
                    .foregroundStyle(statusColor)

                Spacer()

                if host.kind == .ssh {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host.sshCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy SSH command")
                }

                Button {
                    store.connectInTerminal(host)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(openInTerminalHelp)
                .disabled(!host.isConnectable)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            terminalPanel
        }
    }

    @ViewBuilder
    private var terminalPanel: some View {
        if session.isRunning {
            ZStack(alignment: .topLeading) {
                store.configuration.terminalTheme.terminalBackgroundSwiftUIColor(colorScheme: colorScheme)

                TerminalTextView(
                    session: session,
                    initialText: "",
                    theme: store.configuration.terminalTheme,
                    isActive: true
                )
                .id(host.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            WorkspaceIdleView()
        }
    }

    private var statusIcon: String {
        switch session.state {
        case .idle:
            return "circle"
        case .connecting:
            return "clock"
        case .running:
            return "checkmark.circle.fill"
        case .disconnected:
            return "minus.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .idle:
            return .secondary
        case .connecting:
            return .blue
        case .running:
            return .green
        case .disconnected:
            return .secondary
        case .failed:
            return .red
        }
    }

    private var openInTerminalHelp: String {
        switch host.kind {
        case .ssh:
            return "Open in Apple Terminal; saved passwords are used by the embedded session only."
        case .local:
            return "Open this local shell in Apple Terminal."
        }
    }

    private func disconnectSSHHost() {
        guard session.isRunning else { return }
        guard !store.configuration.confirmBeforeDisconnectingSSHHost || confirmDisconnectSSHHost() else { return }

        session.stop()
    }

    private func confirmDisconnectSSHHost() -> Bool {
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

}

private struct LocalTerminalWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ConfigurationStore
    @Binding var host: HostRecord
    @ObservedObject var workspaces: LocalTerminalWorkspaceStore
    let onConnect: (HostRecord) -> Void
    let onNewTab: (HostRecord) -> Void
    @State private var draggingTabID: LocalTerminalTab.ID?
    @State private var lastMovedTabDropID: LocalTerminalTab.ID?
    @State private var didMoveTabToEnd = false

    private var tabs: [LocalTerminalTab] {
        workspaces.tabs(for: host.id)
    }

    private var selectedTab: LocalTerminalTab? {
        workspaces.selectedTab(for: host.id)
    }

    private var selectedTabID: LocalTerminalTab.ID? {
        selectedTab?.id
    }

    private var selectedSession: PTYSession? {
        selectedTab?.session
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            tabBar

            Divider()

            terminalPanel
        }
        .onAppear {
            workspaces.ensureWorkspace(for: host)
        }
        .onChange(of: host.id) { _, _ in
            workspaces.ensureWorkspace(for: host)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(host.title)
                .font(.headline)
                .lineLimit(1)
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

            Button {
                onConnect(host)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!host.isConnectable || (selectedSession?.isRunning ?? false))

            Button {
                stopSelectedTab()
            } label: {
                Label("Stop", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint((selectedSession?.isRunning ?? false) ? .red : .gray)
            .disabled(!(selectedSession?.isRunning ?? false))

            Divider()
                .frame(height: 18)

            Label(selectedSession?.state.title ?? "Ready", systemImage: statusIcon)
                .foregroundStyle(statusColor)

            Spacer()

            Button {
                onNewTab(host)
            } label: {
                Image(systemName: "plus")
            }
            .help("New Tab")

            Button {
                store.connectInTerminal(host)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .help("Open this local shell in Apple Terminal.")
            .disabled(!host.isConnectable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    tabButton(for: tab)
                }

                Color.clear
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.text],
                        delegate: LocalTerminalTabEndDropDelegate(
                            draggingTabID: $draggingTabID,
                            lastMovedTabDropID: $lastMovedTabDropID,
                            didMoveTabToEnd: $didMoveTabToEnd,
                            moveToEnd: { tabID in
                                workspaces.moveTabToEnd(tabID, for: host.id)
                            }
                        )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }

    private func tabButton(for tab: LocalTerminalTab) -> some View {
        LocalTerminalTabButton(
            tab: tab,
            isSelected: selectedTabID == tab.id,
            select: {
                workspaces.selectTab(tab.id, for: host.id)
            },
            rename: { title in
                workspaces.renameTab(tab.id, for: host.id, title: title)
            },
            close: {
                closeTab(tab)
            }
        )
        .opacity(tabOpacity(for: tab.id))
        .onDrag {
            dragItemProvider(for: tab.id)
        }
        .onDrop(
            of: [.text],
            delegate: LocalTerminalTabDropDelegate(
                targetTabID: tab.id,
                draggingTabID: $draggingTabID,
                lastMovedTabDropID: $lastMovedTabDropID,
                didMoveTabToEnd: $didMoveTabToEnd,
                move: { sourceTabID, targetTabID in
                    workspaces.moveTab(sourceTabID, to: targetTabID, for: host.id)
                }
            )
        )
    }

    private func tabOpacity(for tabID: LocalTerminalTab.ID) -> Double {
        draggingTabID == tabID ? 0.55 : 1
    }

    private func dragItemProvider(for tabID: LocalTerminalTab.ID) -> NSItemProvider {
        draggingTabID = tabID
        return NSItemProvider(object: tabID.uuidString as NSString)
    }

    private func stopSelectedTab() {
        guard selectedSession?.isRunning == true else { return }
        guard !store.configuration.confirmBeforeStoppingLocalTerminalTab || confirmStopSelectedTab() else { return }

        workspaces.stopSelectedTab(for: host.id)
    }

    private func closeTab(_ tab: LocalTerminalTab) {
        guard !store.configuration.confirmBeforeClosingLocalTerminalTab || confirmCloseTab(tab) else { return }

        workspaces.closeTab(tab.id, for: host)
    }

    private func confirmStopSelectedTab() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop Shell?"
        alert.informativeText = "This will terminate the current shell tab."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            store.setConfirmBeforeStoppingLocalTerminalTab(false)
        }
        return confirmed
    }

    private func confirmCloseTab(_ tab: LocalTerminalTab) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close Tab?"
        alert.informativeText = tab.session.isRunning
            ? "This will close \(tab.title) and terminate its running shell."
            : "This will close \(tab.title)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let confirmed = alert.runModal() == .alertFirstButtonReturn
        if confirmed, alert.suppressionButton?.state == .on {
            store.setConfirmBeforeClosingLocalTerminalTab(false)
        }
        return confirmed
    }

    @ViewBuilder
    private var terminalPanel: some View {
        ZStack(alignment: .topLeading) {
            store.configuration.terminalTheme.terminalBackgroundSwiftUIColor(colorScheme: colorScheme)

            ForEach(tabs) { tab in
                if tab.session.isRunning {
                    let isActive = selectedTabID == tab.id

                    TerminalTextView(
                        session: tab.session,
                        initialText: "",
                        theme: store.configuration.terminalTheme,
                        isActive: isActive
                    )
                    .id(tab.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(isActive)
                    .zIndex(isActive ? 1 : 0)
                }
            }

            if !(selectedSession?.isRunning ?? false) {
                TerminalTabIdleView()
            }
        }
    }

    private var statusIcon: String {
        switch selectedSession?.state ?? .idle {
        case .idle:
            return "circle"
        case .connecting:
            return "clock"
        case .running:
            return "checkmark.circle.fill"
        case .disconnected:
            return "minus.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch selectedSession?.state ?? .idle {
        case .idle:
            return .secondary
        case .connecting:
            return .blue
        case .running:
            return .green
        case .disconnected:
            return .secondary
        case .failed:
            return .red
        }
    }
}

private struct LocalTerminalTabDropDelegate: DropDelegate {
    let targetTabID: LocalTerminalTab.ID
    @Binding var draggingTabID: LocalTerminalTab.ID?
    @Binding var lastMovedTabDropID: LocalTerminalTab.ID?
    @Binding var didMoveTabToEnd: Bool
    let move: (LocalTerminalTab.ID, LocalTerminalTab.ID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggingTabID, draggingTabID != targetTabID else { return }
        move(draggingTabID, targetTabID)
        lastMovedTabDropID = targetTabID
        didMoveTabToEnd = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let didDrop = draggingTabID != nil
        if let draggingTabID,
           draggingTabID != targetTabID,
           lastMovedTabDropID != targetTabID {
            move(draggingTabID, targetTabID)
        }
        draggingTabID = nil
        lastMovedTabDropID = nil
        didMoveTabToEnd = false
        return didDrop
    }
}

private struct LocalTerminalTabEndDropDelegate: DropDelegate {
    @Binding var draggingTabID: LocalTerminalTab.ID?
    @Binding var lastMovedTabDropID: LocalTerminalTab.ID?
    @Binding var didMoveTabToEnd: Bool
    let moveToEnd: (LocalTerminalTab.ID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let draggingTabID else { return }
        moveToEnd(draggingTabID)
        lastMovedTabDropID = nil
        didMoveTabToEnd = true
    }

    func performDrop(info: DropInfo) -> Bool {
        let didDrop = draggingTabID != nil
        if let draggingTabID, !didMoveTabToEnd {
            moveToEnd(draggingTabID)
        }
        draggingTabID = nil
        lastMovedTabDropID = nil
        didMoveTabToEnd = false
        return didDrop
    }
}

private struct LocalTerminalTabButton: View {
    let tab: LocalTerminalTab
    let isSelected: Bool
    let select: () -> Void
    let rename: (String) -> Void
    let close: () -> Void
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            titleControl

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close Tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            if !isRenaming {
                select()
            }
        }
        .contextMenu {
            Button {
                beginRenaming()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Button {
                close()
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        .onAppear {
            draftTitle = tab.title
        }
        .onChange(of: tab.title) { _, newTitle in
            if !isRenaming {
                draftTitle = newTitle
            }
        }
    }

    @ViewBuilder
    private var titleControl: some View {
        if isRenaming {
            TextField("Tab Name", text: $draftTitle)
                .textFieldStyle(.plain)
                .frame(minWidth: 74, maxWidth: 150)
                .focused($isTitleFocused)
                .onSubmit(commitRename)
                .onChange(of: isTitleFocused) { _, isFocused in
                    if !isFocused {
                        commitRename()
                    }
                }
                .onAppear {
                    isTitleFocused = true
                }
        } else {
            HStack(spacing: 6) {
                Image(systemName: tab.session.isRunning ? "bolt.circle.fill" : "circle")
                    .foregroundStyle(tab.session.isRunning ? .green : .secondary)

                Text(tab.title)
                    .lineLimit(1)
            }
        }
    }

    private func beginRenaming() {
        draftTitle = tab.title
        isRenaming = true
        isTitleFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }

        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            rename(trimmedTitle)
        } else {
            draftTitle = tab.title
        }

        isRenaming = false
        isTitleFocused = false
    }
}

private struct TerminalTabIdleView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .regular))

                Text("Click Start to open this tab")
                    .font(.body)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct WorkspaceIdleView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .regular))

                Text("Double click a host to start")
                    .font(.body)

                HStack(spacing: 6) {
                    Text("or click")
                    Image(systemName: "plus")
                    Text("to add a new host")
                }
                .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct HostEditorView: View {
    @Binding var host: HostRecord

    private var tagText: Binding<String> {
        Binding(
            get: { host.tags.joined(separator: ", ") },
            set: { newValue in
                host.tags = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    var body: some View {
        Form {
            Section("Identity") {
                Picker("Type", selection: $host.kind) {
                    ForEach(HostKind.allCases) { kind in
                        Text(kind.title)
                            .tag(kind)
                    }
                }
                .pickerStyle(.menu)

                TextField("Name", text: $host.name)
                TextField("Group", text: $host.group)
                TextField("Tags", text: tagText)
            }

            Section("Connection") {
                switch host.kind {
                case .ssh:
                    TextField("Host", text: $host.hostname)
                        .textContentType(.URL)

                    TextField("User", text: $host.username)

                    HStack {
                        Text("Password")
                        Spacer()
                        SecureField("", text: $host.password)
                            .frame(maxWidth: 260)

                        Button {
                            host.password = ""
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Clear saved password")
                        .disabled(host.password.isEmpty)
                    }

                    Stepper(value: $host.port, in: 1...65535) {
                        TextField("Port", value: $host.port, format: .number)
                    }

                    TextField("Identity File", text: $host.identityFile)
                case .local:
                    TextField("Working Directory", text: $host.localWorkingDirectory)
                    LabeledContent("Shell") {
                        Text(host.localShellPath)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Notes") {
                TextEditor(text: $host.notes)
                    .font(.body)
                    .frame(minHeight: 110)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
    }
}
