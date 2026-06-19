import AppKit
import MetalKit

class BlackHoleWindow: NSWindow, NSWindowDelegate {
    var metalView: MTKView?
    var renderer: BlackHoleRenderer?
    let isDemo: Bool
    let isManual: Bool
    let delayMinutes: Double
    let duration: Double?
    let captureDir: String?
    let captureTimes: [Double]

    init(isDemo: Bool, isManual: Bool, delayMinutes: Double, duration: Double?, captureDir: String?, captureTimes: [Double]) {
        self.isDemo = isDemo
        self.isManual = isManual
        self.delayMinutes = delayMinutes
        self.duration = duration
        self.captureDir = captureDir
        self.captureTimes = captureTimes

        guard let mainScreen = NSScreen.main else {
            fatalError("No main screen found")
        }
        let frame = mainScreen.frame

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.delegate = self

        // Metal view fills the window
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available on this system")
        }

        let mtkView = MTKView(frame: frame, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.layer?.isOpaque = false
        mtkView.wantsLayer = true

        self.metalView = mtkView
        self.contentView = mtkView

        guard let r = BlackHoleRenderer(
            device: device,
            view: mtkView,
            isDemo: isDemo,
            isManual: isManual,
            delayMinutes: delayMinutes,
            duration: duration,
            captureDir: captureDir,
            captureTimes: captureTimes
        ) else {
            fatalError("Failed to create renderer")
        }
        self.renderer = r

        // Trigger first draw
        mtkView.setNeedsDisplay(mtkView.bounds)

        // In manual mode, stay hidden until the terminal command "start".
        if isManual {
            self.orderOut(nil)
        } else {
            self.makeKeyAndOrderFront(nil)
            self.orderFrontRegardless()
        }

        // Periodic redraw
        startRenderLoop()
    }

    override var canBecomeKey: Bool { !isManual }
    override var canBecomeMain: Bool { !isManual }

    func startRenderLoop() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.metalView else { return }
            view.setNeedsDisplay(view.bounds)
        }
    }

    func becomeKeyAfterTrigger() {
        // Show the overlay after terminal command "start" without stealing focus.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.orderFrontRegardless()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // In manual mode before trigger, guard against accidental key presses.
        // The window should not be key before trigger, but if an event slips through:
        if isManual && renderer?.hasTriggered == false {
            if event.keyCode == 49 { // Space
                print("Space pressed — starting black hole collapse.")
                renderer?.triggerManual()
                becomeKeyAfterTrigger()
            }
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 49: // Space
            if isManual && renderer?.hasTriggered == false {
                print("Space pressed — starting black hole collapse.")
                renderer?.triggerManual()
                becomeKeyAfterTrigger()
            }
        case 53: // Escape
            print("Escape pressed — playing exit animation.")
            renderer?.requestExitAnimation()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Keep visible even when losing focus
        self.orderFrontRegardless()
    }
}
