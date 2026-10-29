import AppKit
import Foundation
import ServiceManagement

struct ReceivedFile: Identifiable {
    let id = UUID()
    let url: URL
    let date: Date
}

/// App state shown in the menu bar window. Always mutated on the main thread.
final class Store: ObservableObject {
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/LIVEFOLDER", isDirectory: true)

    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "folder"); ensureFolder() }
    }
    @Published var listening = false
    @Published var listenError: String?
    @Published var port: UInt16 = 0

    // From Pi heartbeat
    @Published var piHost: String?
    @Published var piIP: String?
    @Published var camera: String?
    @Published var piQueue = 0
    @Published var lastHeartbeat: Date?

    @Published var recent: [ReceivedFile] = []
    @Published var receivedCount = 0
    @Published var flash = false
    @Published var now = Date()

    private var timer: Timer?

    init() {
        if let p = UserDefaults.standard.string(forKey: "folder") {
            folder = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            folder = Store.defaultFolder
        }
        ensureFolder()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
    }

    var piOnline: Bool {
        guard let t = lastHeartbeat else { return false }
        return now.timeIntervalSince(t) < 8
    }

    func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Pilih"
        panel.message = "Pilih folder untuk gambar yang masuk"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }

    func openFolder() {
        ensureFolder()
        NSWorkspace.shared.open(folder)
    }

    func reveal(_ file: ReceivedFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func resetFolder() { folder = Store.defaultFolder }

    // Called by Receiver (on main)
    func didReceive(_ url: URL) {
        receivedCount += 1
        recent.insert(ReceivedFile(url: url, date: Date()), at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.flash = false }
    }

    func didHeartbeat(_ json: [String: Any]) {
        piHost = json["host"] as? String
        piIP = json["ip"] as? String
        camera = json["camera"] as? String
        piQueue = json["queue"] as? Int ?? 0
        lastHeartbeat = Date()
        now = Date()
    }

    // Launch at login (works when the app lives in /Applications)
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login failed: \(error)")
            }
            objectWillChange.send()
        }
    }
}
