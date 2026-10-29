import CryptoKit
import Foundation
import Network

/// Listens on the LAN, advertises itself with Bonjour (_jstether._tcp) so the
/// Pi finds this Mac automatically, and accepts:
///   POST /upload?name=DSC01234.JPG   (body = JPEG, header X-SHA256)
///   POST /status                     (body = JSON heartbeat from the Pi)
final class Receiver {
    static let preferredPort: UInt16 = 47800
    static let serviceType = "_jstether._tcp"

    private let store: Store
    private let queue = DispatchQueue(label: "jstether.receiver")
    private var listener: NWListener?

    init(store: Store) { self.store = store }

    func start() { start(port: Receiver.preferredPort) }

    private func start(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let endpointPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let l: NWListener
        do {
            l = try NWListener(using: params, on: endpointPort)
        } catch {
            if port != 0 { start(port: 0) } else { report(error: "\(error)") }
            return
        }
        let name = Host.current().localizedName ?? "Mac"
        l.service = NWListener.Service(name: name, type: Receiver.serviceType)
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                let p = l.port?.rawValue ?? 0
                DispatchQueue.main.async {
                    self.store.listening = true
                    self.store.port = p
                    self.store.listenError = nil
                }
            case .failed(let err):
                l.cancel()
                if port != 0 {
                    // preferred port busy: take any free port (Bonjour tells the Pi which)
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.start(port: 0) }
                } else {
                    self.report(error: err.localizedDescription)
                    self.queue.asyncAfter(deadline: .now() + 3) { self.start(port: 0) }
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            HTTPConnection(conn, store: self.store, queue: self.queue).start()
        }
        l.start(queue: queue)
        listener = l
    }

    private func report(error: String) {
        DispatchQueue.main.async {
            self.store.listening = false
            self.store.listenError = error
        }
    }
}

/// One HTTP/1.1 request per connection (the Pi sends Connection: close).
final class HTTPConnection {
    private enum Mode { case status, upload }

    private let conn: NWConnection
    private let store: Store
    private let queue: DispatchQueue

    private var head = Data()
    private var headDone = false
    private var finished = false
    private var mode: Mode = .status
    private var headers: [String: String] = [:]
    private var query: [String: String] = [:]
    private var remaining = 0

    private var body = Data()
    private var folder: URL!
    private var fileName = "photo.jpg"
    private var tempURL: URL?
    private var handle: FileHandle?
    private var hasher = SHA256()

    init(_ conn: NWConnection, store: Store, queue: DispatchQueue) {
        self.conn = conn
        self.store = store
        self.queue = queue
    }

    func start() {
        conn.start(queue: queue)
        receive()
    }

    // The receive callbacks hold a strong reference to self until the
    // connection is cancelled, which keeps this object alive.
    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            if let data, !data.isEmpty { self.consume(data) }
            if self.finished { return }
            if error != nil || isComplete { self.abort(); return }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        guard !finished else { return }
        if headDone { bodyChunk(data); return }

        head.append(data)
        guard let r = head.range(of: Data("\r\n\r\n".utf8)) else {
            if head.count > 32_768 { respond(431, "header too large") }
            return
        }
        let headBytes = head.subdata(in: head.startIndex..<r.lowerBound)
        let rest = head.subdata(in: r.upperBound..<head.endIndex)
        head = Data()
        headDone = true
        guard parseHead(headBytes), begin() else { return }
        if headers["expect"]?.lowercased() == "100-continue" {
            conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
        }
        if remaining == 0 { finish(); return }
        if !rest.isEmpty { bodyChunk(rest) }
    }

    private func parseHead(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { respond(400, "bad request"); return false }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2, requestLine[0] == "POST" else {
            respond(405, "POST only"); return false
        }
        let target = String(requestLine[1])
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        let comps = URLComponents(string: "http://pi" + target)
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        switch comps?.path ?? "" {
        case "/status": mode = .status
        case "/upload": mode = .upload
        default: respond(404, "not found"); return false
        }
        remaining = Int(headers["content-length"] ?? "") ?? -1
        if remaining < 0 { respond(411, "length required"); return false }
        return true
    }

    /// Prepare to receive the body. Returns false if it already responded with an error.
    private func begin() -> Bool {
        switch mode {
        case .status:
            if remaining > 65_536 { respond(413, "too large"); return false }
            return true
        case .upload:
            if remaining == 0 || remaining > 500_000_000 { respond(413, "bad size"); return false }
            folder = DispatchQueue.main.sync { store.folder }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fileName = Self.safeName(query["name"] ?? "photo.jpg")
            // Hidden temp file in the same folder -> atomic rename when complete,
            // so other apps watching the folder never see half a JPG.
            let tmp = folder.appendingPathComponent(".\(fileName).\(UUID().uuidString).partial")
            guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: tmp) else {
                respond(500, "cannot write to folder"); return false
            }
            tempURL = tmp
            handle = h
            return true
        }
    }

    private func bodyChunk(_ data: Data) {
        let n = min(remaining, data.count)
        let chunk = n == data.count ? data : data.prefix(n)
        switch mode {
        case .status:
            body.append(chunk)
        case .upload:
            do { try handle?.write(contentsOf: chunk) } catch {
                abortUpload(); respond(500, "write failed"); return
            }
            hasher.update(data: chunk)
        }
        remaining -= n
        if remaining == 0 { finish() }
    }

    private func finish() {
        switch mode {
        case .status:
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                DispatchQueue.main.async { self.store.didHeartbeat(obj) }
            }
            respond(200, "ok")
        case .upload:
            try? handle?.close()
            handle = nil
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expected = headers["x-sha256"]?.lowercased(), expected != digest {
                abortUpload(); respond(422, "checksum mismatch"); return
            }
            guard let tmp = tempURL else { respond(500, "no temp"); return }
            let base = folder.appendingPathComponent(fileName)
            // Pi re-sent a file we already have (e.g. our reply got lost): keep one copy.
            if Self.sameFile(base, digest: digest) {
                try? FileManager.default.removeItem(at: tmp)
                respond(200, "duplicate"); return
            }
            let dest = Self.uniqueURL(base)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                abortUpload(); respond(500, "move failed"); return
            }
            tempURL = nil
            DispatchQueue.main.async { self.store.didReceive(dest) }
            respond(200, "saved")
        }
    }

    private func respond(_ code: Int, _ message: String) {
        guard !finished else { return }
        finished = true
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
                      411: "Length Required", 413: "Payload Too Large", 422: "Unprocessable Entity",
                      431: "Request Header Fields Too Large", 500: "Internal Server Error"][code] ?? "Error"
        let json = "{\"ok\":\(code == 200),\"message\":\"\(message)\"}"
        let resp = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n" + json
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
            self.conn.cancel()
        })
    }

    private func abortUpload() {
        try? handle?.close()
        handle = nil
        if let t = tempURL { try? FileManager.default.removeItem(at: t) }
        tempURL = nil
    }

    private func abort() {
        abortUpload()
        finished = true
        conn.cancel()
    }

    // MARK: helpers

    static func safeName(_ raw: String) -> String {
        var name = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "photo.jpg" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext != "jpg" && ext != "jpeg" { name += ".jpg" }
        return name
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 1
        while true {
            let candidate = dir.appendingPathComponent("\(stem)-\(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    static func sameFile(_ url: URL, digest: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest
    }
}
