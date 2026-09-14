import Foundation
import Cocoa
import IOBluetooth

// Private IOBluetooth call that blueutil uses as well: switches the controller on/off
// without root. Used when blueutil is not installed.
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
func IOBluetoothPreferenceSetControllerPowerState(_ state: Int32)

class BluetoothDaemon {
    private let pidFile = "/tmp/bluetooth_daemon.pid"
    private let logFile = "/tmp/bluetooth_daemon.log"
    private var bluetoothManager: BluetoothController!
    private var sleepDelayTimer: Timer?
    private let sleepDelaySeconds: TimeInterval = 5.0
    
    init() {
        bluetoothManager = BluetoothController()
        setupSignalHandlers()
        writePidFile()
        setupLogging()
    }
    
    func run() {
        log("🚀 BluetoothDaemon started")
        
        // Регистрируем уведомления о сне и пробуждении
        registerSleepNotifications()
        
        // Запускаем run loop
        log("⏳ Daemon is running and waiting for system events...")
        RunLoop.current.run()
    }
    
    deinit {
        cleanup()
    }
    
    private func setupSignalHandlers() {
        // Обработка сигналов для корректного завершения
        // Remove the PID file on exit so a stale PID (possibly reused by another
        // process) is never left behind for the GUI to signal.
        signal(SIGTERM) { _ in
            unlink("/tmp/bluetooth_daemon.pid")
            _exit(0)
        }
        
        signal(SIGINT) { _ in
            unlink("/tmp/bluetooth_daemon.pid")
            _exit(0)
        }
    }
    
    private func writePidFile() {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        try? pid.write(toFile: pidFile, atomically: true, encoding: .utf8)
    }
    
    private func setupLogging() {
        // Перенаправляем stdout в лог файл
        freopen(logFile.cString(using: .utf8), "a", stdout)
        freopen(logFile.cString(using: .utf8), "a", stderr)
    }
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        print("[\(timestamp)] \(message)")
        fflush(stdout)
    }
    
    private func registerSleepNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        log("📡 Sleep/wake notifications registered")
    }
    
    @objc private func systemWillSleep() {
        log("💤 System will sleep - starting \(sleepDelaySeconds) second countdown...")
        
        // Отменяем предыдущий таймер, если есть
        sleepDelayTimer?.invalidate()
        
        // Запускаем таймер на 5 секунд
        sleepDelayTimer = Timer.scheduledTimer(withTimeInterval: sleepDelaySeconds, repeats: false) { _ in
            self.log("⏰ Sleep delay expired - disabling Bluetooth")
            if self.bluetoothManager.isEnabled {
                self.bluetoothManager.disableBluetooth()
                self.log("🔵 Bluetooth disabled after \(self.sleepDelaySeconds) second delay")
            } else {
                self.log("🔵 Bluetooth was already disabled")
            }
        }
        
        log("⏳ Bluetooth will be disabled in \(sleepDelaySeconds) seconds unless system wakes up...")
    }
    
    @objc private func systemDidWake() {
        log("☀️ System did wake - checking if we need to cancel sleep timer...")
        
        // Отменяем таймер отключения, если система проснулась
        if let timer = sleepDelayTimer, timer.isValid {
            timer.invalidate()
            sleepDelayTimer = nil
            log("✅ Sleep timer cancelled - Bluetooth stays connected!")
        } else {
            log("⚠️ No active sleep timer found")
        }
        
        // Небольшая задержка для стабильности системы
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !self.bluetoothManager.isEnabled {
                self.bluetoothManager.enableBluetooth()
                self.log("🔵 Bluetooth enabled after wake")
            } else {
                self.log("🔵 Bluetooth was already enabled")
            }
        }
    }
    
    private func cleanup() {
        log("🧹 Cleaning up daemon...")
        
        // Отменяем активный таймер сна
        sleepDelayTimer?.invalidate()
        sleepDelayTimer = nil
        
        // Удаляем PID файл
        try? FileManager.default.removeItem(atPath: pidFile)
        
        // Удаляем наблюдателей
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        
        log("👋 Daemon stopped")
    }
}

// Контроллер для управления Bluetooth
class BluetoothController {
    var isEnabled: Bool {
        let powerState = IOBluetoothHostController.default()?.powerState
        return powerState == kBluetoothHCIPowerStateON
    }
    
    func enableBluetooth() {
        print("🔄 Attempting to enable Bluetooth...")
        
        // Метод 1: blueutil (если установлен) - более надежный
        if let blueutil = blueutilPath, executeShellCommand("'\(blueutil)' -p 1") {
            print("✅ Bluetooth enabled via blueutil")
            return
        }
        
        // Метод 2: IOBluetooth (то же, что делает blueutil, без sudo)
        IOBluetoothPreferenceSetControllerPowerState(1)
        Thread.sleep(forTimeInterval: 1.0)
        if isEnabled {
            print("✅ Bluetooth enabled via IOBluetooth")
            return
        }
        
        // Метод 3: AppleScript (как запасной вариант)
        let script = """
        tell application "System Events"
            tell process "SystemUIServer"
                try
                    tell (menu bar item 1 of menu bar 1 whose description contains "bluetooth")
                        click
                        tell (menu item "Turn Bluetooth On" of menu 1)
                            click
                        end tell
                    end tell
                end try
            end tell
        end tell
        """
        
        if executeAppleScript(script) {
            print("✅ Bluetooth enabled via AppleScript")
        } else {
            print("❌ All Bluetooth enable methods failed")
        }
    }
    
    func disableBluetooth() {
        print("🔄 Attempting to disable Bluetooth...")
        
        // Метод 1: blueutil (если установлен) - более надежный
        if let blueutil = blueutilPath, executeShellCommand("'\(blueutil)' -p 0") {
            print("✅ Bluetooth disabled via blueutil")
            return
        }
        
        // Метод 2: IOBluetooth (то же, что делает blueutil, без sudo)
        IOBluetoothPreferenceSetControllerPowerState(0)
        Thread.sleep(forTimeInterval: 1.0)
        if !isEnabled {
            print("✅ Bluetooth disabled via IOBluetooth")
            return
        }
        
        // Метод 3: AppleScript (как запасной вариант)
        let script = """
        tell application "System Events"
            tell process "SystemUIServer"
                try
                    tell (menu bar item 1 of menu bar 1 whose description contains "bluetooth")
                        click
                        tell (menu item "Turn Bluetooth Off" of menu 1)
                            click
                        end tell
                    end tell
                end try
            end tell
        end tell
        """
        
        if executeAppleScript(script) {
            print("✅ Bluetooth disabled via AppleScript")
        } else {
            print("❌ All Bluetooth disable methods failed")
        }
    }
    
    // A daemon started from the GUI inherits launchd's PATH, which has no Homebrew
    // directories, so look blueutil up explicitly.
    private var blueutilPath: String? {
        ["/opt/homebrew/bin/blueutil", "/usr/local/bin/blueutil"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    
    private func executeAppleScript(_ script: String) -> Bool {
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        
        if let error = error {
            print("❌ AppleScript error: \(error)")
            return false
        }
        
        if result != nil {
            print("✅ AppleScript executed successfully")
            return true
        }
        
        return false
    }
    
    private func executeShellCommand(_ command: String) -> Bool {
        print("🔧 Executing: \(command)")
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        
        // Захватываем stderr для диагностики
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if task.terminationStatus == 0 {
                print("✅ Command succeeded")
                if !output.isEmpty {
                    print("📤 Output: \(output)")
                }
                return true
            } else {
                print("❌ Command failed with exit code: \(task.terminationStatus)")
                if !output.isEmpty {
                    print("📤 Error output: \(output)")
                }
                return false
            }
        } catch {
            print("❌ Shell command error: \(error)")
            return false
        }
    }
}

// Точка входа для daemon'а
let daemon = BluetoothDaemon()
daemon.run() 