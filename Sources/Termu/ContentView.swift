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

private enum SidebarLayout {
    static let minWidth: CGFloat = 260
    static let idealWidth: CGFloat = 320
    static let maxWidth: CGFloat = 420
    static let titlebarHeight: CGFloat = 50
    static let titlebarControlLeading: CGFloat = 78
    static let titlebarControlTop: CGFloat = -21
    static let resizeHitWidth: CGFloat = 12
    static let collapsedDetailToolbarInset: CGFloat = 154
}

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: ConfigurationStore
    @StateObject private var sshSessions = SSHSessionStore()
    @StateObject private var localWorkspaces = LocalTerminalWorkspaceStore()
    @State private var filter: HostFilter = .all
    @State private var searchText = ""
    @State private var editingHostID: HostRecord.ID?
    @State private var isSidebarVisible = true
    @State private var sidebarWidth: CGFloat = SidebarLayout.idealWidth
    @State private var hostPendingDeletion: HostRecord?
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
                .overlay(alignment: .trailing) {
                    SidebarResizeHandle(
                        sidebarWidth: $sidebarWidth,
                        isSidebarVisible: isSidebarVisible
                    )
                    .frame(width: SidebarLayout.resizeHitWidth)
                    .frame(maxHeight: .infinity)
                    .zIndex(2)
                    .allowsHitTesting(isSidebarVisible)
                }

            detailColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChromeConfigurator())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isSidebarVisible)
        .overlay(alignment: .topLeading) {
            sidebarToggleButton
                .padding(.leading, SidebarLayout.titlebarControlLeading)
                .padding(.top, SidebarLayout.titlebarControlTop)
        }
        .onAppear(perform: prepareSelectedHost)
        .onReceive(NotificationCenter.default.publisher(for: .termuRequestDeleteSelectedHost)) { _ in
            if let host = store.selectedHost {
                requestDelete(host)
            }
        }
        .onChange(of: store.selectedHostID) { _, _ in
            prepareSelectedHost()
            if editingHostID != store.selectedHostID {
                editingHostID = nil
            }
        }
        .alert("Delete Host?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let host = hostPendingDeletion {
                    delete(host)
                }
                hostPendingDeletion = nil
            }

            Button("Cancel", role: .cancel) {
                hostPendingDeletion = nil
            }
        } message: {
            if let host = hostPendingDeletion {
                Text("This will remove \(host.title) and stop any active session. This cannot be undone.")
            } else {
                Text("This host will be removed. This cannot be undone.")
            }
        }
        .onChange(of: isShowingDeleteConfirmation) { _, isShowing in
            if !isShowing {
                hostPendingDeletion = nil
            }
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: SidebarLayout.titlebarHeight)

            HostSidebarView(
                filter: $filter,
                searchText: $searchText,
                editingHostID: $editingHostID,
                isRunning: isRunning,
                connect: connect,
                disconnect: disconnect,
                requestDelete: requestDelete
            )
        }
        .background(SidebarFrostedBackground())
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity)
        .frame(width: isSidebarVisible ? sidebarWidth : 0, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(isSidebarVisible)
        .accessibilityHidden(!isSidebarVisible)
    }

    private var sidebarToggleButton: some View {
        Button {
            isSidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(.borderless)
        .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .option])
    }

    private var detailColumn: some View {
        DetailView(
            sshSessions: sshSessions,
            localWorkspaces: localWorkspaces,
            connect: connect,
            newLocalTab: newLocalTab,
            topBarLeadingInset: isSidebarVisible ? 0 : SidebarLayout.collapsedDetailToolbarInset
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            if isSidebarVisible {
                DetailLeadingShadow()
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func requestDelete(_ host: HostRecord) {
        guard let currentHost = store.hosts.first(where: { $0.id == host.id }) else { return }
        store.selectHost(currentHost.id)
        hostPendingDeletion = currentHost
        isShowingDeleteConfirmation = true
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
    let requestDelete: (HostRecord) -> Void

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

            hostList
                .frame(
                    minHeight: editingHostID == store.selectedHostID ? 160 : 220,
                    maxHeight: .infinity
                )

            if editingHostID == store.selectedHostID,
               let host = store.selectedHostBinding {
                Divider()

                SidebarEditorPanel(host: host) {
                    editingHostID = nil
                }
                .frame(minHeight: 320)
            }

            Divider()
                .padding(.trailing, 1)

            SidebarSettingsButton(isShowingSettings: $isShowingSettings)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

            NewHostMenuButton {
                store.addHost(kind: .ssh)
                editingHostID = store.selectedHostID
            } addLocal: {
                store.addHost(kind: .local)
                editingHostID = store.selectedHostID
            }
            .frame(width: 42, height: 28)
            .help("New Host")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 44)
    }

    @ViewBuilder
    private var hostList: some View {
        if filteredHosts.isEmpty {
            ContentUnavailableView(
                "No Hosts",
                systemImage: "server.rack",
                description: Text("Add a host to start building your terminal workspace.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    requestDelete(host)
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

private struct NewHostMenuButton: NSViewRepresentable {
    let addSSH: () -> Void
    let addLocal: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(addSSH: addSSH, addLocal: addLocal)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Host") ?? NSImage(),
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "New Host"
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.addSSH = addSSH
        context.coordinator.addLocal = addLocal
    }

    final class Coordinator: NSObject {
        var addSSH: () -> Void
        var addLocal: () -> Void

        init(addSSH: @escaping () -> Void, addLocal: @escaping () -> Void) {
            self.addSSH = addSSH
            self.addLocal = addLocal
        }

        @MainActor @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()

            let sshItem = NSMenuItem(
                title: "SSH Host",
                action: #selector(addSSHHost),
                keyEquivalent: ""
            )
            sshItem.target = self
            sshItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            menu.addItem(sshItem)

            let localItem = NSMenuItem(
                title: "Local",
                action: #selector(addLocalHost),
                keyEquivalent: ""
            )
            localItem.target = self
            localItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            menu.addItem(localItem)

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 4),
                in: sender
            )
        }

        @MainActor @objc private func addSSHHost() {
            addSSH()
        }

        @MainActor @objc private func addLocalHost() {
            addLocal()
        }
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat
    let isSidebarVisible: Bool

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        SidebarResizeHandleView()
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        nsView.sidebarWidth = sidebarWidth
        nsView.minWidth = SidebarLayout.minWidth
        nsView.maxWidth = SidebarLayout.maxWidth
        nsView.isSidebarVisible = isSidebarVisible
        nsView.onWidthChanged = { sidebarWidth = $0 }
    }
}

private final class SidebarResizeHandleView: NSView {
    var sidebarWidth: CGFloat = SidebarLayout.idealWidth
    var minWidth: CGFloat = SidebarLayout.minWidth
    var maxWidth: CGFloat = SidebarLayout.maxWidth
    var isSidebarVisible = true {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onWidthChanged: ((CGFloat) -> Void)?

    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var dragStartWindowX: CGFloat?
    private var dragStartWidth: CGFloat = SidebarLayout.idealWidth
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isSidebarVisible, bounds.contains(point) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isSidebarVisible {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartWindowX = event.locationInWindow.x
        dragStartWidth = sidebarWidth
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWindowX else { return }
        let delta = event.locationInWindow.x - dragStartWindowX
        let nextWidth = clampedWidth(dragStartWidth + delta)
        sidebarWidth = nextWidth
        onWidthChanged?(nextWidth)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWindowX = nil
        sidebarWidth = clampedWidth(sidebarWidth)
        onWidthChanged?(sidebarWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSidebarVisible else { return }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        let lineRect = NSRect(
            x: bounds.maxX - lineWidth,
            y: 0,
            width: lineWidth,
            height: bounds.height
        )
        NSColor.separatorColor.setFill()
        lineRect.fill()
    }

    private func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}

private struct DetailLeadingShadow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 1)
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.12),
                radius: 8,
                x: -3,
                y: 0
            )
    }
}

private struct SidebarFrostedBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SidebarVisualEffectBackground()
            .overlay(
                Color.white.opacity(colorScheme == .dark ? 0.06 : 0.36)
            )
            .overlay(
                Color(nsColor: .windowBackgroundColor)
                    .opacity(colorScheme == .dark ? 0.03 : 0.10)
            )
    }
}

private struct SidebarVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
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
    let topBarLeadingInset: CGFloat

    var body: some View {
        if let host = store.selectedHostBinding {
            HostDetailView(
                host: host,
                sshSessions: sshSessions,
                localWorkspaces: localWorkspaces,
                onConnect: connect,
                onNewLocalTab: newLocalTab,
                topBarLeadingInset: topBarLeadingInset
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

    private var showAIActivityIndicator: Binding<Bool> {
        Binding(
            get: { store.configuration.showAIActivityIndicator },
            set: { store.setShowAIActivityIndicator($0) }
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
            AppAboutHeader()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Terminal Theme")
                    .font(.subheadline)
                    .fontWeight(.medium)

                ThemeModeToggle(selection: terminalTheme)

                Toggle("Show AI activity indicator", isOn: showAIActivityIndicator)
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

                    SyncRefreshButton {
                        store.refreshICloud()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct SyncRefreshButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotationDegrees = 0.0
    @State private var isFlashActive = false
    let action: () -> Void

    var body: some View {
        Button {
            triggerRefresh()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFlashActive ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 28)
                .rotationEffect(.degrees(rotationDegrees))
                .background(
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                )
                .overlay(
                    Circle()
                        .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Refresh iCloud sync")
    }

    private func triggerRefresh() {
        action()

        if reduceMotion {
            isFlashActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isFlashActive = false
            }
        } else {
            withAnimation(.easeInOut(duration: 0.42)) {
                rotationDegrees += 360
            }
        }
    }
}

private struct AppAboutHeader: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String

        switch (version, build) {
        case let (version?, build?) where !build.isEmpty:
            return "Version \(version) (\(build))"
        case let (version?, _):
            return "Version \(version)"
        default:
            return "Version Unknown"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)

            VStack(spacing: 2) {
                Text("About Termu")
                    .font(.headline)
                Text(versionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 4)
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
