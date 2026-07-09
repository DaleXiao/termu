import AppKit
import CoreText
import SwiftTerm
import SwiftUI

struct TerminalTextView: NSViewRepresentable {
    private static let minimumUsableColumns = 20
    private static let minimumUsableRows = 2
    private static let terminalFontSize: CGFloat = 13
    private static var didRegisterPreferredFonts = false

    @Environment(\.colorScheme) private var colorScheme

    let session: PTYSession
    let initialText: String
    let theme: TerminalTheme
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalContainerView {
        let terminalView = TermuTerminalView(
            frame: TerminalContainerView.initialTerminalFrame,
            font: Self.makeTerminalFont()
        )
        let container = TerminalContainerView(terminalView: terminalView)
        container.setActive(isActive)

        let shouldRequestFocus = context.coordinator.bind(
            terminalView: terminalView,
            session: session,
            initialText: initialText,
            theme: theme,
            colorScheme: colorScheme,
            isActive: isActive
        )
        if shouldRequestFocus {
            context.coordinator.requestFocus()
        }

        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        let terminalView = container.terminalView
        container.setActive(isActive)

        let shouldRequestFocus = context.coordinator.bind(
            terminalView: terminalView,
            session: session,
            initialText: initialText,
            theme: theme,
            colorScheme: colorScheme,
            isActive: isActive
        )

        if !session.isRunning {
            context.coordinator.showIdleText(initialText)
        }

        if shouldRequestFocus {
            context.coordinator.requestFocus()
        }
    }

    private static func makeTerminalFont() -> NSFont {
        registerPreferredFontsIfNeeded()

        let preferredFontNames = [
            "Maple Mono NF",
            "MapleMono-NF-Regular",
            "Maple Mono NF Regular",
            "MesloLGS NF",
            "JetBrainsMono Nerd Font",
            "Hack Nerd Font",
            "CaskaydiaCove Nerd Font",
            "FiraCode Nerd Font",
            "Symbols Nerd Font Mono"
        ]

        for fontName in preferredFontNames {
            if let font = NSFont(name: fontName, size: terminalFontSize) {
                return font
            }
        }

        return NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .regular)
    }

    private static func registerPreferredFontsIfNeeded() {
        guard !didRegisterPreferredFonts else { return }
        didRegisterPreferredFonts = true

        let fontsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts", isDirectory: true)
        guard let fontURLs = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for fontURL in fontURLs where fontURL.lastPathComponent.hasPrefix("MapleMono-NF-") {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
            _ = error?.takeRetainedValue()
        }
    }

    static func dismantleNSView(_ container: TerminalContainerView, coordinator: Coordinator) {
        coordinator.unbind()
        container.terminalView.terminalDelegate = nil
    }

    final class TerminalContainerView: NSView {
        static let initialTerminalFrame = CGRect(x: 0, y: 0, width: 1_000, height: 600)

        let terminalView: TerminalView
        private var pendingTerminalLayoutUpdate: DispatchWorkItem?

        override var isFlipped: Bool {
            true
        }

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        init(terminalView: TerminalView) {
            self.terminalView = terminalView
            super.init(frame: .zero)

            autoresizesSubviews = false
            clipsToBounds = true
            wantsLayer = true
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func layout() {
            super.layout()
            guard terminalView.superview === self else { return }
            guard terminalView.terminalDelegate != nil else { return }
            guard bounds.width > 0, bounds.height > 0 else { return }

            if terminalView.frame != bounds {
                terminalView.frame = bounds
                scheduleTerminalLayoutUpdate()
            } else {
                notifyTerminalSizeChanged()
            }
        }

        private func scheduleTerminalLayoutUpdate() {
            guard pendingTerminalLayoutUpdate == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingTerminalLayoutUpdate = nil
                self.updateTerminalLayout()
            }
            pendingTerminalLayoutUpdate = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func updateTerminalLayout() {
            guard terminalView.superview === self else { return }
            guard bounds.width > 0, bounds.height > 0 else { return }

            terminalView.getTerminal().updateFullScreen()
            terminalView.setNeedsDisplay(terminalView.bounds)
            notifyTerminalSizeChanged()
        }

        private func notifyTerminalSizeChanged() {
            let dims = terminalView.getTerminal().getDims()
            terminalView.terminalDelegate?.sizeChanged(
                source: terminalView,
                newCols: dims.cols,
                newRows: dims.rows
            )
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            needsLayout = true
        }

        func setActive(_ isActive: Bool) {
            if isActive {
                let becameActive = isHidden || terminalView.superview !== self
                isHidden = false
                if terminalView.superview !== self {
                    addSubview(terminalView)
                }
                needsLayout = true
                terminalView.setNeedsDisplay(terminalView.bounds)
                if becameActive {
                    refreshTerminalLayoutImmediately()
                }
            } else {
                pendingTerminalLayoutUpdate?.cancel()
                pendingTerminalLayoutUpdate = nil
                terminalView.removeFromSuperview()
                isHidden = true
            }
        }

        private func refreshTerminalLayoutImmediately() {
            pendingTerminalLayoutUpdate?.cancel()
            pendingTerminalLayoutUpdate = nil

            guard terminalView.superview === self else { return }
            guard terminalView.terminalDelegate != nil else { return }
            guard bounds.width > 0, bounds.height > 0 else { return }

            if terminalView.frame != bounds {
                terminalView.frame = bounds
            }
            updateTerminalLayout()
        }
    }

    final class TermuTerminalView: TerminalView {
        override var mouseDownCanMoveWindow: Bool {
            false
        }
    }

    @MainActor
    final class Coordinator: NSObject, PTYSessionTerminalRenderer, @preconcurrency TerminalViewDelegate {
        private weak var terminalView: TerminalView?
        private weak var session: PTYSession?
        private var renderedInitialText = ""
        private var appliedTheme: TerminalTheme?
        private var appliedColorScheme: ColorScheme?
        private var wasActive = false
        private var isActive = false
        private var needsFullRedrawOnActivation = false
        private var lastTerminalSize: (cols: Int, rows: Int)?
        private var pendingResizeWorkItem: DispatchWorkItem?
        private var pendingTerminalDataWorkItem: DispatchWorkItem?
        private var pendingFocusWorkItems: [DispatchWorkItem] = []
        private var isReadyForTerminalData = false
        private var isResizePending = false
        private var pendingTerminalData = Data()
        private static let resizeDebounceDelay: TimeInterval = 0.08

        @discardableResult
        func bind(
            terminalView: TerminalView,
            session: PTYSession,
            initialText: String,
            theme: TerminalTheme,
            colorScheme: ColorScheme,
            isActive: Bool
        ) -> Bool {
            var shouldRequestFocus = false
            var shouldApplyTheme = appliedTheme != theme || appliedColorScheme != colorScheme

            let terminalViewChanged = self.terminalView !== terminalView
            if terminalViewChanged {
                self.terminalView = terminalView
                isReadyForTerminalData = false
                pendingTerminalDataWorkItem?.cancel()
                pendingTerminalDataWorkItem = nil
                pendingTerminalData.removeAll()
                configure(terminalView)
                shouldRequestFocus = isActive
                shouldApplyTheme = true
            }

            let sessionChanged = self.session !== session
            if sessionChanged {
                shouldRequestFocus = isActive
                shouldApplyTheme = true
            }

            if shouldApplyTheme {
                apply(theme, colorScheme: colorScheme, to: terminalView)
                appliedTheme = theme
                appliedColorScheme = colorScheme
            }

            if sessionChanged {
                pendingResizeWorkItem?.cancel()
                pendingResizeWorkItem = nil
                isResizePending = false
                pendingTerminalDataWorkItem?.cancel()
                pendingTerminalDataWorkItem = nil
                lastTerminalSize = nil
                if terminalViewChanged {
                    isReadyForTerminalData = false
                }
                pendingTerminalData.removeAll()
                self.session?.setAIActivityMonitoringVisible(false)
                self.session?.detachTerminalRenderer(self)
                self.session = session
                session.attachTerminalRenderer(self, initialText: initialText)
            }

            let becameActive = isActive && !wasActive
            self.isActive = isActive
            session.setAIActivityMonitoringVisible(isActive)

            if becameActive {
                shouldRequestFocus = true
                flushPendingTerminalData()
                redrawFullTerminal(terminalView)
                needsFullRedrawOnActivation = false
            } else if isActive, needsFullRedrawOnActivation {
                redrawFullTerminal(terminalView)
                needsFullRedrawOnActivation = false
            }
            wasActive = isActive

            return shouldRequestFocus
        }

        func unbind() {
            pendingResizeWorkItem?.cancel()
            pendingResizeWorkItem = nil
            isResizePending = false
            pendingTerminalDataWorkItem?.cancel()
            pendingTerminalDataWorkItem = nil
            cancelPendingFocusRequests()
            pendingTerminalData.removeAll()
            session?.setAIActivityMonitoringVisible(false)
            session?.detachTerminalRenderer(self)
            session = nil
            terminalView = nil
        }

        func showIdleText(_ text: String) {
            guard renderedInitialText != text else { return }
            resetTerminal(initialText: text)
        }

        func resetTerminal(initialText: String) {
            renderedInitialText = initialText
            pendingTerminalDataWorkItem?.cancel()
            pendingTerminalDataWorkItem = nil
            pendingTerminalData.removeAll()
            guard let terminalView else { return }

            terminalView.feed(text: "\u{1B}c")
            terminalView.feed(text: initialText)
            redrawFullTerminal(terminalView)
        }

        func feedTerminalData(_ data: Data) {
            guard terminalView != nil else { return }

            pendingTerminalData.append(data)
            guard isActive, isReadyForTerminalData, !isResizePending else { return }
            schedulePendingTerminalDataFlush()
        }

        private func renderTerminalData(_ data: Data, in terminalView: TerminalView) {
            guard !data.isEmpty else { return }

            let bytes = [UInt8](data)
            terminalView.feed(byteArray: bytes[...])
        }

        private func schedulePendingTerminalDataFlush() {
            guard pendingTerminalDataWorkItem == nil else { return }

            let workItem = DispatchWorkItem { [weak self] in
                self?.flushPendingTerminalData()
            }
            pendingTerminalDataWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func flushPendingTerminalData() {
            pendingTerminalDataWorkItem?.cancel()
            pendingTerminalDataWorkItem = nil

            guard isReadyForTerminalData,
                  !pendingTerminalData.isEmpty,
                  let terminalView else {
                return
            }

            let data = pendingTerminalData
            pendingTerminalData.removeAll(keepingCapacity: true)
            renderTerminalData(data, in: terminalView)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard newCols >= TerminalTextView.minimumUsableColumns,
                  newRows >= TerminalTextView.minimumUsableRows else {
                return
            }

            let newTerminalSize = (newCols, newRows)
            guard lastTerminalSize?.cols != newTerminalSize.0 || lastTerminalSize?.rows != newTerminalSize.1 else {
                if !isResizePending {
                    isReadyForTerminalData = true
                    flushPendingTerminalData()
                }
                return
            }
            let shouldResizeImmediately = lastTerminalSize == nil
            lastTerminalSize = (newCols, newRows)

            redrawFullTerminal(source)
            pendingResizeWorkItem?.cancel()
            if shouldResizeImmediately {
                session?.resize(cols: newCols, rows: newRows)
                isResizePending = false
                isReadyForTerminalData = true
                flushPendingTerminalData()
                return
            }

            isResizePending = true
            isReadyForTerminalData = false

            let workItem = DispatchWorkItem { [weak self, weak session] in
                guard let self, self.session === session else { return }
                session?.resize(cols: newCols, rows: newRows)
                self.isResizePending = false
                self.isReadyForTerminalData = true
                if let terminalView = self.terminalView {
                    self.redrawFullTerminal(terminalView)
                }
                self.flushPendingTerminalData()
            }
            pendingResizeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounceDelay, execute: workItem)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session?.send(data)
        }

        func scrolled(source: TerminalView, position: Double) {
            guard isActive else {
                needsFullRedrawOnActivation = true
                return
            }

            // SwiftTerm only marks the scroll boundary rows dirty for scrollback-backed
            // output. termu uses partial redraws for performance, so an actual scroll
            // must repaint the whole visible terminal to avoid stale row fragments.
            redrawFullTerminal(source)
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            guard let string = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }

        func clipboardRead(source: TerminalView) -> Data? {
            NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) {
            NSSound.beep()
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func requestFocus() {
            cancelPendingFocusRequests()
            focusAfterDelay(0)
            focusAfterDelay(0.05)
            focusAfterDelay(0.15)
        }

        private func configure(_ terminalView: TerminalView) {
            terminalView.terminalDelegate = self
            terminalView.autoresizingMask = []
            terminalView.wantsLayer = true
            terminalView.clipsToBounds = true
            terminalView.layer?.masksToBounds = true
            terminalView.layer?.needsDisplayOnBoundsChange = true
            terminalView.disableFullRedrawOnAnyChanges = false
            terminalView.optionAsMetaKey = true
            terminalView.allowMouseReporting = true
            terminalView.linkHighlightMode = .hoverWithModifier
            terminalView.caretViewTracksFocus = true
        }

        private func apply(_ theme: TerminalTheme, colorScheme: ColorScheme, to terminalView: TerminalView) {
            let backgroundColor = theme.terminalBackgroundColor(colorScheme: colorScheme)
            terminalView.layer?.backgroundColor = backgroundColor.cgColor
            terminalView.nativeBackgroundColor = backgroundColor
            terminalView.nativeForegroundColor = theme.terminalForegroundColor(colorScheme: colorScheme)
            terminalView.caretColor = theme.terminalCaretColor(colorScheme: colorScheme)
            terminalView.selectedTextBackgroundColor = theme.terminalSelectedTextBackgroundColor(colorScheme: colorScheme)
            redrawFullTerminal(terminalView)
        }

        private func redrawFullTerminal(_ terminalView: TerminalView) {
            terminalView.getTerminal().updateFullScreen()
            terminalView.setNeedsDisplay(terminalView.bounds)
        }

        private func focusAfterDelay(_ delay: TimeInterval) {
            let workItem = DispatchWorkItem { [weak self] in
                guard let terminalView = self?.terminalView else { return }
                terminalView.window?.makeFirstResponder(terminalView)
            }
            pendingFocusWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func cancelPendingFocusRequests() {
            pendingFocusWorkItems.forEach { $0.cancel() }
            pendingFocusWorkItems.removeAll(keepingCapacity: true)
        }
    }
}
