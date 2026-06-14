import AppKit
import SwiftUI

@MainActor
extension TerminalTheme {
    var terminalBackgroundColor: NSColor {
        terminalBackgroundColor(colorScheme: currentColorScheme)
    }

    var terminalForegroundColor: NSColor {
        terminalForegroundColor(colorScheme: currentColorScheme)
    }

    var terminalCaretColor: NSColor {
        terminalCaretColor(colorScheme: currentColorScheme)
    }

    var terminalSelectedTextBackgroundColor: NSColor {
        terminalSelectedTextBackgroundColor(colorScheme: currentColorScheme)
    }

    var terminalBackgroundSwiftUIColor: Color {
        Color(nsColor: terminalBackgroundColor)
    }

    func terminalBackgroundColor(colorScheme: ColorScheme) -> NSColor {
        usesDarkAppearance(colorScheme: colorScheme) ? .black : NSColor(calibratedWhite: 0.98, alpha: 1)
    }

    func terminalForegroundColor(colorScheme: ColorScheme) -> NSColor {
        usesDarkAppearance(colorScheme: colorScheme)
            ? NSColor(calibratedWhite: 0.92, alpha: 1)
            : NSColor(calibratedWhite: 0.08, alpha: 1)
    }

    func terminalCaretColor(colorScheme: ColorScheme) -> NSColor {
        usesDarkAppearance(colorScheme: colorScheme) ? .systemGreen : .systemBlue
    }

    func terminalSelectedTextBackgroundColor(colorScheme: ColorScheme) -> NSColor {
        usesDarkAppearance(colorScheme: colorScheme)
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.80, alpha: 1)
    }

    func terminalBackgroundSwiftUIColor(colorScheme: ColorScheme) -> Color {
        Color(nsColor: terminalBackgroundColor(colorScheme: colorScheme))
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

    private func usesDarkAppearance(colorScheme: ColorScheme) -> Bool {
        switch self {
        case .dark:
            return true
        case .light:
            return false
        case .system:
            return colorScheme == .dark
        }
    }

    private var currentColorScheme: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
