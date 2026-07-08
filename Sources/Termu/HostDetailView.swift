import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HostDetailView: View {
    @Binding var host: HostRecord
    @ObservedObject var sshSessions: SSHSessionStore
    @ObservedObject var localWorkspaces: LocalTerminalWorkspaceStore
    let onConnect: (HostRecord) -> Void
    let onNewLocalTab: (HostRecord) -> Void
    let topBarLeadingInset: CGFloat

    var body: some View {
        switch host.kind {
        case .ssh:
            SessionView(
                host: $host,
                session: sshSessions.session(for: host),
                onConnect: onConnect,
                topBarLeadingInset: topBarLeadingInset
            )
        case .local:
            LocalTerminalWorkspaceView(
                host: $host,
                workspaces: localWorkspaces,
                onConnect: onConnect,
                onNewTab: onNewLocalTab,
                topBarLeadingInset: topBarLeadingInset
            )
        }
    }
}

private enum DetailToolbarLayout {
    static let height: CGFloat = 50
}

private struct SessionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ConfigurationStore
    @Binding var host: HostRecord
    @ObservedObject var session: PTYSession
    let onConnect: (HostRecord) -> Void
    let topBarLeadingInset: CGFloat

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
            .padding(.leading, 16 + topBarLeadingInset)
            .padding(.trailing, 16)
            .frame(height: DetailToolbarLayout.height)
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
            .overlay(alignment: .top) {
                AIActivityIndicatorLine(
                    isActive: store.configuration.showAIActivityIndicator && session.isAIActivityActive
                )
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
    let topBarLeadingInset: CGFloat
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
                ToolbarActionLabel(title: "Start", systemImage: "play.fill", iconXOffset: -0.5)
            }
            .buttonStyle(TerminalToolbarActionButtonStyle(kind: .start))
            .disabled(!host.isConnectable || (selectedSession?.isRunning ?? false))

            Button {
                stopSelectedTab()
            } label: {
                ToolbarActionLabel(title: "Stop", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(TerminalToolbarActionButtonStyle(kind: .stop))
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
        .padding(.leading, 16 + topBarLeadingInset)
        .padding(.trailing, 16)
        .frame(height: DetailToolbarLayout.height)
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
        .overlay(alignment: .top) {
            AIActivityIndicatorLine(isActive: shouldShowAIActivityIndicator)
        }
    }

    private var shouldShowAIActivityIndicator: Bool {
        store.configuration.showAIActivityIndicator && (selectedSession?.isAIActivityActive ?? false)
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

private struct AIActivityIndicatorLine: View {
    let isActive: Bool

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    GeometryReader { geometry in
                        let width = max(geometry.size.width, 1)
                        let sweepWidth = min(max(width * 0.22, 120), 360)
                        let duration = 1.35
                        let progress = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: duration) / duration
                        let xOffset = -sweepWidth + (width + sweepWidth * 2) * progress

                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(height: 1)

                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.accentColor.opacity(0),
                                            Color.accentColor.opacity(0.95),
                                            Color.accentColor.opacity(0)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: sweepWidth, height: 2)
                                .offset(x: xOffset)
                                .shadow(color: Color.accentColor.opacity(0.35), radius: 4)
                        }
                        .frame(width: width, height: 4, alignment: .leading)
                        .clipped()
                    }
                    .frame(height: 4)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 4)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: isActive)
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

private struct ToolbarActionLabel: View {
    let title: String
    let systemImage: String
    var iconXOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 14, height: 14)
                .offset(x: iconXOffset)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(minWidth: 72)
    }
}

private struct TerminalToolbarActionButtonStyle: ButtonStyle {
    enum Kind {
        case start
        case stop
    }

    @Environment(\.isEnabled) private var isEnabled
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(backgroundColor)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(borderColor, lineWidth: 1)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.64)
        }

        switch kind {
        case .start:
            return .white
        case .stop:
            return .white
        }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.10)
        }

        switch kind {
        case .start:
            return Color.accentColor
        case .stop:
            return Color.red.opacity(0.88)
        }
    }

    private var borderColor: Color {
        if !isEnabled {
            return Color.secondary.opacity(0.14)
        }

        switch kind {
        case .start:
            return Color.accentColor.opacity(0.72)
        case .stop:
            return Color.red.opacity(0.62)
        }
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
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ConfigurationStore

    var body: some View {
        ZStack {
            Rectangle()
                .fill(store.configuration.terminalTheme.terminalBackgroundSwiftUIColor(colorScheme: colorScheme))

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 34, weight: .regular))

                Text("Click Start to open this tab")
                    .font(.body)
            }
            .foregroundStyle(store.configuration.terminalTheme.terminalForegroundSwiftUIColor(colorScheme: colorScheme).opacity(0.65))
        }
    }
}

struct WorkspaceIdleView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ConfigurationStore

    var body: some View {
        ZStack {
            Rectangle()
                .fill(store.configuration.terminalTheme.terminalBackgroundSwiftUIColor(colorScheme: colorScheme))

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
            .foregroundStyle(store.configuration.terminalTheme.terminalForegroundSwiftUIColor(colorScheme: colorScheme).opacity(0.65))
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
