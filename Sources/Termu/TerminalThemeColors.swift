import AppKit
import SwiftUI

@MainActor
extension TerminalTheme {
    var terminalBackgroundColor: NSColor {
        usesDarkAppearance ? .black : NSColor(calibratedWhite: 0.98, alpha: 1)
    }

    var terminalForegroundColor: NSColor {
        usesDarkAppearance ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.08, alpha: 1)
    }

    var terminalCaretColor: NSColor {
        usesDarkAppearance ? .systemGreen : .systemBlue
    }

    var terminalSelectedTextBackgroundColor: NSColor {
        usesDarkAppearance ? NSColor(calibratedWhite: 0.22, alpha: 1) : NSColor(calibratedWhite: 0.80, alpha: 1)
    }

    var terminalBackgroundSwiftUIColor: Color {
        Color(nsColor: terminalBackgroundColor)
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .dark:
            return .dark
        case .light:
            return .light
        case .system:
            return nil
        }
    }

    private var usesDarkAppearance: Bool {
        switch self {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}
