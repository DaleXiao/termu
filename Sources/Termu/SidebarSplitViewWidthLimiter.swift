import AppKit
import SwiftUI

private final class EventMonitorBox: @unchecked Sendable {
    let monitor: Any

    init(_ monitor: Any) {
        self.monitor = monitor
    }
}

struct SidebarSplitViewWidthLimiter: NSViewRepresentable {
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onDividerDrag: () -> Void

    func makeNSView(context: Context) -> SidebarSplitViewWidthLimiterView {
        SidebarSplitViewWidthLimiterView(minWidth: minWidth, maxWidth: maxWidth, onDividerDrag: onDividerDrag)
    }

    func updateNSView(_ nsView: SidebarSplitViewWidthLimiterView, context: Context) {
        nsView.update(minWidth: minWidth, maxWidth: maxWidth, onDividerDrag: onDividerDrag)
    }
}

@MainActor
final class SidebarSplitViewWidthLimiterView: NSView {
    private var minWidth: CGFloat
    private var maxWidth: CGFloat
    private var onDividerDrag: () -> Void
    private var eventMonitor: EventMonitorBox?
    private var isTrackingDividerDrag = false

    init(minWidth: CGFloat, maxWidth: CGFloat, onDividerDrag: @escaping () -> Void) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.onDividerDrag = onDividerDrag
        super.init(frame: .zero)
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor.monitor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installEventMonitorIfNeeded()
        scheduleApply()
    }

    func update(minWidth: CGFloat, maxWidth: CGFloat, onDividerDrag: @escaping () -> Void) {
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.onDividerDrag = onDividerDrag
        installEventMonitorIfNeeded()
        scheduleApply()
    }

    private func scheduleApply() {
        DispatchQueue.main.async { [weak self] in
            self?.apply()
        }
    }

    private func apply() {
        guard let splitView = splitViewContainingSelf() else { return }
        guard let sidebarView = directChild(in: splitView) else { return }
        guard let splitViewController = splitViewController(for: splitView) else { return }
        guard let splitViewItem = splitViewController.splitViewItems.first(where: { item in
            item.viewController.view === sidebarView
                || sidebarView.isDescendant(of: item.viewController.view)
                || item.viewController.view.isDescendant(of: sidebarView)
        }) else { return }

        splitViewItem.minimumThickness = minWidth
        splitViewItem.maximumThickness = maxWidth
        splitViewItem.canCollapse = false
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            self?.handle(event)
            return event
        }) else { return }
        eventMonitor = EventMonitorBox(monitor)
    }

    private func handle(_ event: NSEvent) {
        guard event.window === window else { return }
        guard let splitView = splitViewContainingSelf() else { return }
        guard let sidebarView = directChild(in: splitView) else { return }

        let point = splitView.convert(event.locationInWindow, from: nil)
        let dividerX = sidebarView.frame.maxX
        let isNearDivider = abs(point.x - dividerX) <= 10
        let isBelowTitlebar = point.y > 56

        switch event.type {
        case .leftMouseDown:
            isTrackingDividerDrag = isBelowTitlebar && isNearDivider
            if isTrackingDividerDrag {
                onDividerDrag()
            }
        case .leftMouseDragged:
            if isTrackingDividerDrag || (isBelowTitlebar && isNearDivider) {
                isTrackingDividerDrag = true
                onDividerDrag()
            }
        case .leftMouseUp:
            if isTrackingDividerDrag {
                onDividerDrag()
            }
            isTrackingDividerDrag = false
        default:
            break
        }
    }

    private func splitViewContainingSelf() -> NSSplitView? {
        var view: NSView? = self
        while let current = view {
            if let splitView = current as? NSSplitView {
                return splitView
            }
            view = current.superview
        }

        return nil
    }

    private func splitViewController(for splitView: NSSplitView) -> NSSplitViewController? {
        var responder = splitView.nextResponder
        while let current = responder {
            if let splitViewController = current as? NSSplitViewController {
                return splitViewController
            }
            responder = current.nextResponder
        }

        return window?.contentViewController?.firstSplitViewController(containing: splitView)
    }

    private func directChild(in splitView: NSSplitView) -> NSView? {
        var current: NSView? = self
        var child: NSView?

        while let view = current, view !== splitView {
            child = view
            current = view.superview
        }

        guard current === splitView else { return nil }
        return child
    }
}

private extension NSViewController {
    func firstSplitViewController(containing splitView: NSSplitView) -> NSSplitViewController? {
        if let splitViewController = self as? NSSplitViewController,
           splitViewController.splitView === splitView {
            return splitViewController
        }

        for child in children {
            if let splitViewController = child.firstSplitViewController(containing: splitView) {
                return splitViewController
            }
        }

        return nil
    }
}
