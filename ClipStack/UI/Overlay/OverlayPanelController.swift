import AppKit
import SwiftUI

/// Shows/hides the overlay panel on the screen containing the mouse, and owns
/// the local key-event monitor for overlay navigation.
@MainActor
final class OverlayPanelController {
    private let panel: OverlayPanel
    private let viewModel: OverlayViewModel
    private var keyMonitor: Any?

    private static let panelHeight: CGFloat = 340
    private static let horizontalInset: CGFloat = 16
    private static let bottomInset: CGFloat = 8

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel
        panel = OverlayPanel()

        let hostingView = NSHostingView(rootView: OverlayView(viewModel: viewModel))
        panel.contentView = hostingView

        panel.onResignKey = { [weak self] in
            self?.hide()
        }
        viewModel.requestHide = { [weak self] in
            self?.hide()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.minX + Self.horizontalInset,
            y: visible.minY + Self.bottomInset,
            width: visible.width - Self.horizontalInset * 2,
            height: Self.panelHeight
        )
        panel.setFrame(frame, display: true)

        viewModel.prepareForShow()
        installKeyMonitor()
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // MARK: - Keyboard handling

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.window === self.panel else { return event }
            return self.handle(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Returns nil when the event was consumed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // While the preview's text editor is active, all keys belong to it —
        // except Esc, which cancels editing.
        if viewModel.isEditingPreview {
            if event.keyCode == 53 {
                viewModel.isEditingPreview = false
                return nil
            }
            return event
        }

        let command = event.modifierFlags.contains(.command)
        let shiftOrOption = !event.modifierFlags.intersection([.shift, .option]).isEmpty

        // ⌘1…⌘9 — quick paste
        if command, let chars = event.charactersIgnoringModifiers,
           chars.count == 1, let digit = Int(chars), (1...9).contains(digit)
        {
            viewModel.pasteAt(position: digit)
            return nil
        }

        // ⌘C — copy without pasting
        if command, event.charactersIgnoringModifiers == "c" {
            viewModel.copySelected()
            return nil
        }

        // ⌘P — pin/unpin selected
        if command, event.charactersIgnoringModifiers == "p" {
            viewModel.togglePinSelected()
            return nil
        }

        switch event.keyCode {
        case 53: // Esc — close preview first, then the overlay
            if viewModel.previewClip != nil {
                viewModel.closePreview()
            } else {
                hide()
            }
            return nil
        case 49 where viewModel.searchText.isEmpty || viewModel.previewClip != nil:
            // Space — toggle large preview (passes through while typing a search)
            viewModel.togglePreview()
            return nil
        case 123: // ←
            viewModel.moveSelection(by: -1)
            return nil
        case 124: // →
            viewModel.moveSelection(by: 1)
            return nil
        case 36, 76: // Return / keypad Enter
            viewModel.pasteSelected(plainText: shiftOrOption)
            return nil
        case 51 where command: // ⌘⌫ — delete selected clip
            viewModel.deleteSelected()
            return nil
        default:
            return event // everything else goes to the search field
        }
    }
}
