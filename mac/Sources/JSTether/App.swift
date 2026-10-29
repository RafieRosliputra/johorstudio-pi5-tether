import SwiftUI

@main
struct JSTetherApp: App {
    @StateObject private var store: Store
    private let receiver: Receiver

    init() {
        let s = Store()
        _store = StateObject(wrappedValue: s)
        receiver = Receiver(store: s)
        receiver.start()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuIcon: String {
        if store.flash { return "camera.fill" }
        return store.piOnline ? "camera" : "camera.badge.ellipsis"
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("JohorStudio Tether").font(.headline)
                Spacer()
                Text("\(store.receivedCount) gambar")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                StatusRow(label: "Pi",
                          color: store.piOnline ? .green : .red,
                          text: store.piOnline
                            ? "\(store.piHost ?? "Pi")  \(store.piIP ?? "")"
                            : "Menunggu Pi…")
                StatusRow(label: "Kamera",
                          color: !store.piOnline ? .gray : (store.camera == nil ? .red : .green),
                          text: !store.piOnline ? "—" : (store.camera ?? "Tiada kamera"))
                if store.piOnline && store.piQueue > 0 {
                    StatusRow(label: "Queue", color: .orange,
                              text: "\(store.piQueue) gambar sedang dihantar")
                }
                StatusRow(label: "App",
                          color: store.listening ? .green : .orange,
                          text: store.listening ? "Sedia terima (port \(store.port))"
                                                : (store.listenError ?? "Memulakan…"))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder destinasi").font(.caption).foregroundStyle(.secondary)
                Text(displayPath(store.folder))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .help(store.folder.path)
                HStack {
                    Button("Tukar…") { store.chooseFolder() }
                    Button("Buka") { store.openFolder() }
                    if store.folder.standardizedFileURL.path != Store.defaultFolder.standardizedFileURL.path {
                        Button("Default") { store.resetFolder() }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Gambar terkini").font(.caption).foregroundStyle(.secondary)
                if store.recent.isEmpty {
                    Text("Belum ada gambar masuk").foregroundStyle(.secondary)
                } else {
                    ForEach(store.recent) { file in
                        Button { store.reveal(file) } label: {
                            HStack {
                                Image(systemName: "photo")
                                Text(file.url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(file.date, style: .time).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Tunjuk dalam Finder")
                    }
                }
            }

            Divider()

            HStack {
                Toggle("Buka bila login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.launchAtLogin = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Keluar") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

struct StatusRow: View {
    let label: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.callout)
    }
}
