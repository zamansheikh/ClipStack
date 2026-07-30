import AppKit

/// Borderless, non-activating panel. It can become key (so typing reaches the
/// search field) but never activates ClipStack — the frontmost app keeps focus,
/// so a synthesized ⌘V lands in the right place.
final class OverlayPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Clicking anywhere else dismisses the overlay, Paste-style.
        onResignKey?()
    }
}
