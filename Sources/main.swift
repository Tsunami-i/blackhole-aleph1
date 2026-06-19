import AppKit
import Darwin

// MARK: - CLI argument parsing
struct Config {
    var isDemo = false
    var isManual = false
    var delayMinutes: Double = 0
    var duration: Double? = nil
    var captureDir: String? = nil
    var captureTimes: [Double] = []

    static func parse() -> Config {
        var cfg = Config()
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--demo":
                cfg.isDemo = true
            case "--manual":
                cfg.isManual = true
            case "--delay-min":
                if i + 1 < args.count {
                    cfg.delayMinutes = Double(args[i + 1]) ?? 0
                    i += 1
                }
            case "--duration":
                if i + 1 < args.count {
                    cfg.duration = Double(args[i + 1])
                    i += 1
                }
            case "--capture-dir":
                if i + 1 < args.count {
                    cfg.captureDir = args[i + 1]
                    i += 1
                }
            case "--capture-times":
                if i + 1 < args.count {
                    cfg.captureTimes = args[i + 1]
                        .split(separator: ",")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    i += 1
                }
            case "--help", "-h":
                printHelp()
                exit(0)
            default:
                break
            }
            i += 1
        }
        return cfg
    }

    static func printHelp() {
        print("""
        BlackHoleScreenWarp — macOS global black hole overlay

        USAGE:
          BlackHoleScreenWarp [OPTIONS]

        OPTIONS:
          --demo              Immediately show the black hole effect
          --manual            Wait for terminal command "start"; "exit" plays exit animation
          --delay-min <N>     Start showing effect after N minutes of runtime
          --duration <N>      Auto-exit after N seconds
          --capture-dir <DIR> Write renderer PNG captures to DIR
          --capture-times <T> Comma-separated animation times to capture
          --help, -h          Show this help

        KEYBOARD:
          Esc                 Force exit animation, then quit

        MANUAL TERMINAL COMMANDS:
          start               Trigger effect in --manual mode
          exit                Play exit animation, then quit

        EXAMPLES:
          BlackHoleScreenWarp --demo --duration 10
          BlackHoleScreenWarp --demo --duration 24 --capture-dir verification/run --capture-times 7.2,11,16,22
          BlackHoleScreenWarp --manual
          BlackHoleScreenWarp --delay-min 55
        """)
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: BlackHoleWindow?
    let config: Config
    var eventMonitors: [Any] = []
    var originalTerminalMode: termios?
    var rawTerminalEnabled = false

    init(config: Config) {
        self.config = config
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        window = BlackHoleWindow(
            isDemo: config.isDemo,
            isManual: config.isManual,
            delayMinutes: config.delayMinutes,
            duration: config.duration,
            captureDir: config.captureDir,
            captureTimes: config.captureTimes
        )
        installEscapeMonitors()

        if config.isManual {
            startManualCommandReader()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreTerminalMode()
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        print("BlackHoleScreenWarp exiting.")
    }

    func startManualCommandReader() {
        print("""
        Manual mode ready.
        Type "start" then Enter to trigger the black hole.
        Type "exit" then Enter to play the exit animation and quit.
        """)

        if enableRawTerminalMode() {
            Thread.detachNewThread { [weak self] in
                self?.readManualCommandsRaw()
            }
        } else {
            Thread.detachNewThread { [weak self] in
                while let line = readLine() {
                    self?.handleManualCommand(line)
                }
            }
        }
    }

    func installEscapeMonitors() {
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                self?.handleEscapeShortcut(source: "local Esc")
                return nil
            }
            return event
        }) {
            eventMonitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 {
                self?.handleEscapeShortcut(source: "global Esc")
            }
        }) {
            eventMonitors.append(global)
        }
    }

    func handleEscapeShortcut(source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            print("\(source) — forcing exit animation.")
            self.window?.renderer?.requestExitAnimation()
        }
    }

    func handleManualCommand(_ rawCommand: String) {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch command {
            case "start", "trigger", "go", "space":
                print("Manual command: start")
                self.window?.renderer?.triggerManual()
                self.window?.becomeKeyAfterTrigger()
            case "exit", "quit", "stop", "esc":
                print("Manual command: exit")
                self.window?.renderer?.requestExitAnimation()
            case "":
                break
            default:
                print("Unknown manual command: \(command). Use start or exit.")
            }
        }
    }

    func enableRawTerminalMode() -> Bool {
        guard isatty(STDIN_FILENO) == 1 else { return false }
        var mode = termios()
        guard tcgetattr(STDIN_FILENO, &mode) == 0 else { return false }
        originalTerminalMode = mode
        mode.c_lflag &= ~tcflag_t(ICANON | ECHO)
        mode.c_cc.16 = 1  // VMIN on Darwin
        mode.c_cc.17 = 0  // VTIME on Darwin
        rawTerminalEnabled = tcsetattr(STDIN_FILENO, TCSANOW, &mode) == 0
        return rawTerminalEnabled
    }

    func restoreTerminalMode() {
        guard rawTerminalEnabled, var originalTerminalMode else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &originalTerminalMode)
        rawTerminalEnabled = false
    }

    func readManualCommandsRaw() {
        var buffer = ""
        let input = FileHandle.standardInput

        while true {
            let data = input.readData(ofLength: 1)
            if data.isEmpty { break }
            guard let byte = data.first else { continue }

            if byte == 27 { // Escape
                handleEscapeShortcut(source: "terminal Esc")
                continue
            }

            if byte == 10 || byte == 13 {
                print("")
                handleManualCommand(buffer)
                buffer.removeAll(keepingCapacity: true)
                continue
            }

            if byte == 127 || byte == 8 {
                if !buffer.isEmpty {
                    buffer.removeLast()
                    print("\u{8} \u{8}", terminator: "")
                    fflush(stdout)
                }
                continue
            }

            if let scalar = UnicodeScalar(Int(byte)), !CharacterSet.controlCharacters.contains(scalar) {
                let char = Character(scalar)
                buffer.append(char)
                print(String(char), terminator: "")
                fflush(stdout)
            }
        }
    }
}

// MARK: - Main
let config = Config.parse()
let app = NSApplication.shared
let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
