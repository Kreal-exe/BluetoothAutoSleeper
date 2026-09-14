import Foundation
import IOBluetooth

class DaemonManager: ObservableObject {
    @Published var isDaemonRunning: Bool = false
    @Published var isBluetoothEnabled: Bool = false
    
    private let pidFile = "/tmp/bluetooth_daemon.pid"
    private let logFile = "/tmp/bluetooth_daemon.log"
    private let daemonPath: String
    
    init() {
        // Определяем путь к daemon'у (рядом с основным приложением)
        let appPath = Bundle.main.bundlePath
        let contentsPath = "\(appPath)/Contents/MacOS"
        daemonPath = "\(contentsPath)/BluetoothAutoSleeperDemon"
        
        checkDaemonStatus()
        updateBluetoothStatus()
        
        // Периодически проверяем статус
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.checkDaemonStatus()
            self.updateBluetoothStatus()
        }
    }
    
    func toggleDaemon() {
        if isDaemonRunning {
            stopDaemon()
        } else {
            startDaemon()
        }
    }
    
    func startDaemon() {
        guard !isDaemonRunning else {
            print("Daemon already running")
            return
        }
        
        print("🚀 Starting daemon...")
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: daemonPath)
        task.arguments = []
        
        // Запускаем в фоне
        do {
            try task.run()
            
            // Даем время на запуск
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.checkDaemonStatus()
                if self.isDaemonRunning {
                    print("✅ Daemon started successfully")
                } else {
                    print("❌ Failed to start daemon")
                }
            }
        } catch {
            print("❌ Error starting daemon: \(error)")
        }
    }
    
    func stopDaemon() {
        guard isDaemonRunning else {
            print("Daemon not running")
            return
        }
        
        print("🛑 Stopping daemon...")
        
        guard let pid = getDaemonPid() else {
            print("❌ Cannot get daemon PID")
            return
        }
        
        // Отправляем SIGTERM для корректного завершения
        kill(pid, SIGTERM)
        
        // Проверяем, что процесс завершился
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.checkDaemonStatus()
            if !self.isDaemonRunning {
                print("✅ Daemon stopped successfully")
            } else {
                print("⚠️ Daemon still running, trying SIGKILL...")
                kill(pid, SIGKILL)
            }
        }
    }
    
    func getDaemonLogs() -> String {
        print("📋 Reading logs from: \(logFile)")
        
        // Проверяем, существует ли файл
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logFile) {
            print("❌ Log file does not exist at: \(logFile)")
            return "Log file not found at: \(logFile)\nMake sure the daemon is running."
        }
        
        // Проверяем размер файла
        do {
            let attributes = try fileManager.attributesOfItem(atPath: logFile)
            let fileSize = attributes[.size] as? Int64 ?? 0
            print("📊 Log file size: \(fileSize) bytes")
        } catch {
            print("⚠️ Could not get file attributes: \(error)")
        }
        
        guard let logs = try? String(contentsOfFile: logFile, encoding: .utf8) else {
            print("❌ Could not read log file")
            return "Could not read log file at: \(logFile)\nError reading file contents."
        }
        
        print("✅ Successfully read \(logs.count) characters from log file")
        
        // Возвращаем последние 20 строк
        let lines = logs.components(separatedBy: .newlines)
        let lastLines = Array(lines.suffix(20))
        let result = lastLines.joined(separator: "\n")
        
        print("📤 Returning \(lastLines.count) log lines")
        return result.isEmpty ? "Log file is empty" : result
    }
    
    func clearLogs() {
        try? "".write(toFile: logFile, atomically: true, encoding: .utf8)
    }
    
    private func checkDaemonStatus() {
        guard let pid = getDaemonPid() else {
            isDaemonRunning = false
            return
        }
        
        // Проверяем, что процесс действительно работает
        let result = kill(pid, 0)
        isDaemonRunning = (result == 0)
        
        if !isDaemonRunning {
            // Удаляем устаревший PID файл
            try? FileManager.default.removeItem(atPath: pidFile)
        }
    }
    
    private func getDaemonPid() -> pid_t? {
        guard let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = pid_t(pidString), pid > 0 else {
            return nil
        }
        // /tmp is shared: only trust the PID if it really is our daemon binary,
        // otherwise a stale or planted PID file would make us signal another process.
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0,
              String(cString: buf) == daemonPath else {
            return nil
        }
        return pid
    }
    
    private func updateBluetoothStatus() {
        let powerState = IOBluetoothHostController.default()?.powerState
        isBluetoothEnabled = powerState == kBluetoothHCIPowerStateON
    }
} 