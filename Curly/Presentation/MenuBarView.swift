import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        Label(coordinator.state.statusTitle, systemImage: coordinator.state.statusIconName)
            .accessibilityIdentifier("menu-bar-status-item")
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                StatusMarkView(
                    kind: statusMarkKind
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusCodeText)
                        .font(.system(size: 17, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("menu-bar-status-title")
                    Text(coordinator.state.statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("menu-bar-status-subtitle")
                }
            }

            Divider()

            Button("Rerun Last Request") {
                coordinator.rerunLastRequest()
            }
            .disabled(!coordinator.state.canRerun)
            .accessibilityIdentifier("rerun-last-request-menu-button")

            Button("Open Window") {
                coordinator.requestWindowOpen()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier("open-main-window-menu-button")

            Divider()

            Button("Clear Workspace") {
                coordinator.newWorkspace()
            }
            .accessibilityIdentifier("new-workspace-menu-button")

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .accessibilityIdentifier("quit-menu-button")
        }
        .padding(12)
        .frame(width: 320)
        .accessibilityIdentifier("menu-bar-dropdown")
    }

    private var statusCodeText: String {
        if let statusCode = coordinator.state.visibleResponseState?.summary.statusCode {
            return "\(statusCode)"
        }
        if coordinator.state.executionState == .running {
            return "..."
        }
        return "--"
    }

    private var statusColor: Color {
        switch coordinator.state.statusTone {
        case .neutral:
            if coordinator.state.executionState == .running {
                return .orange
            }
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        }
    }

    private var statusMarkKind: StatusMarkKind {
        switch coordinator.state.statusTone {
        case .neutral:
            if coordinator.state.executionState == .running {
                return .running
            }
            return .idle
        case .success:
            return .success
        case .warning:
            return .warning
        case .failure:
            return .failure
        }
    }
}

private struct StatusMarkView: View {
    let kind: StatusMarkKind

    var body: some View {
        Image(nsImage: StatusBadgeImageFactory.make(kind: kind))
            .resizable()
            .interpolation(.high)
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
    }
}

private enum StatusMarkKind {
    case idle
    case running
    case success
    case warning
    case failure
}

private enum StatusBadgeImageFactory {
    static func make(kind: StatusMarkKind) -> NSImage {
        let size = NSSize(width: 34, height: 34)
        let image = NSImage(size: size, flipped: false) { rect in
            drawBadge(kind: kind, in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawBadge(kind: StatusMarkKind, in rect: NSRect) {
        let circleRect = rect.insetBy(dx: 2, dy: 2)
        let fillColor = fillColor(for: kind)
        let symbolColor = NSColor.white

        fillColor.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        let borderPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
        borderPath.lineWidth = 1
        borderPath.stroke()

        symbolColor.setStroke()
        symbolColor.setFill()

        switch kind {
        case .idle:
            drawMinus(in: rect)
        case .running:
            drawDot(in: rect)
        case .success:
            drawCheck(in: rect)
        case .warning:
            drawBang(in: rect)
        case .failure:
            drawX(in: rect)
        }
    }

    private static func fillColor(for kind: StatusMarkKind) -> NSColor {
        switch kind {
        case .idle:
            return NSColor.controlAccentColor.withAlphaComponent(0.35)
        case .running, .warning:
            return NSColor.systemOrange
        case .success:
            return NSColor.systemGreen
        case .failure:
            return NSColor.systemRed
        }
    }

    private static func drawCheck(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 3.2
        path.move(to: NSPoint(x: rect.minX + 9.5, y: rect.minY + 17))
        path.line(to: NSPoint(x: rect.minX + 15, y: rect.minY + 11.5))
        path.line(to: NSPoint(x: rect.minX + 24.5, y: rect.minY + 22.5))
        path.stroke()
    }

    private static func drawX(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = 3
        path.move(to: NSPoint(x: rect.minX + 11, y: rect.minY + 11))
        path.line(to: NSPoint(x: rect.minX + 23, y: rect.minY + 23))
        path.move(to: NSPoint(x: rect.minX + 23, y: rect.minY + 11))
        path.line(to: NSPoint(x: rect.minX + 11, y: rect.minY + 23))
        path.stroke()
    }

    private static func drawMinus(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = 3
        path.move(to: NSPoint(x: rect.minX + 11, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + 23, y: rect.midY))
        path.stroke()
    }

    private static func drawBang(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineWidth = 3
        path.move(to: NSPoint(x: rect.midX, y: rect.minY + 11))
        path.line(to: NSPoint(x: rect.midX, y: rect.minY + 21.5))
        path.stroke()

        NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.6, y: rect.minY + 24, width: 3.2, height: 3.2)).fill()
    }

    private static func drawDot(in rect: NSRect) {
        NSBezierPath(ovalIn: NSRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6)).fill()
    }
}
