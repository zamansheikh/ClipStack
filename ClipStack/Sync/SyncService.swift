import AppKit
import CryptoKit
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

/// Wi-Fi clipboard sync, Mac side (docs/05-lan-sync.md). The Mac listens and
/// advertises `_clipstack._tcp`; phones connect to it. A local copy goes to
/// every connected paired device; a received copy lands in history and on
/// the Mac's clipboard. v1 never dials out.
@MainActor
final class SyncService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var onlineDeviceIds: Set<String> = []
    /// Non-nil while a pairing window is open and the listener has a port.
    @Published private(set) var pairingLink: String?
    @Published private(set) var isPairingOpen = false
    /// When the current pairing code stops working (for the sheet's countdown).
    @Published private(set) var pairingExpiresAt: Date?
    /// Name of the device paired during the current pairing window.
    @Published private(set) var justPairedName: String?

    let identity: SyncIdentity
    private let database: AppDatabase
    private let settings: AppSettings

    private var listener: NWListener?
    private var triedFallbackPort = false
    private var restartWork: DispatchWorkItem?
    /// Every open connection, including ones still handshaking.
    private var sessions: [SyncSession] = []
    /// The live session per paired device id.
    private var activeSessions: [String: SyncSession] = [:]

    private var pairingToken: Data?
    private var pairingTimer: Timer?
    /// Test hook: keep a pairing window open forever (new token after each
    /// use or expiry).
    private var keepPairingOpen = false
    /// Advertise `_clipstack._tcp` over Bonjour (off only for test runs).
    private var advertise = true
    /// Called with the new link whenever it changes (test hook output).
    var onPairingLinkChanged: ((String?) -> Void)?

    /// Received clip ids, oldest first, for dropping repeats (spec rule 2).
    private var receivedIds: [String] = []
    private var receivedIdSet: Set<String> = []

    private static let pairingLifetime: TimeInterval = 300
    private static let maxSessions = 32

    init(database: AppDatabase, settings: AppSettings) {
        self.database = database
        self.settings = settings
        self.identity = SyncIdentity.loadOrCreate()
        reloadDevices()
    }

    var localDevice: SyncDevice {
        SyncDevice(id: identity.deviceId, name: SyncIdentity.deviceName, platform: SyncProtocol.platform)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        triedFallbackPort = false
        NSLog("ClipStack sync: starting (device \(identity.deviceId))")
        startListener(port: SyncProtocol.defaultPort)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartWork?.cancel()
        restartWork = nil
        listener?.cancel()
        listener = nil
        port = nil
        for session in sessions { session.close() }
        sessions.removeAll()
        activeSessions.removeAll()
        onlineDeviceIds = []
        closePairingWindow()
        NSLog("ClipStack sync: stopped")
    }

    /// Test hook (CLIPSTACK_DEBUG_PAIR_FILE): run sync regardless of the
    /// setting, keep a pairing window open, and mirror its link into a file.
    func startDebugPairing(writingLinkTo path: String) {
        keepPairingOpen = true
        // Tests connect through the link's host/port. Skipping the Bonjour
        // advert keeps a test instance from appearing as a second "Mac" on
        // the network or triggering the Local Network permission prompt.
        advertise = false
        onPairingLinkChanged = { link in
            do {
                try (link ?? "").write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                NSLog("ClipStack sync: cannot write pairing link file: \(error)")
            }
        }
        start()
        openPairingWindow()
    }

    private func startListener(port requested: UInt16?) {
        let parameters = NWParameters.tcp
        let listener: NWListener
        do {
            if let requested, let port = NWEndpoint.Port(rawValue: requested) {
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            NSLog("ClipStack sync: cannot create listener (\(error))")
            if requested != nil {
                startListener(port: nil)
            } else {
                scheduleRestart()
            }
            return
        }

        if advertise {
            listener.service = NWListener.Service(
                name: localDevice.name,
                type: SyncProtocol.serviceType,
                domain: nil,
                txtRecord: txtRecord()
            )
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener else { return }
                self.listener(listener, changedTo: state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(connection)
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func listener(_ listener: NWListener, changedTo state: NWListener.State) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            port = listener.port?.rawValue
            NSLog("ClipStack sync: listening on port \(port.map(String.init) ?? "?")"
                + (advertise ? ", advertising \(SyncProtocol.serviceType)" : ", Bonjour off (test mode)"))
            rebuildPairingLink()
        case .waiting(let error):
            // Typically Local Network permission not granted yet.
            NSLog("ClipStack sync: listener waiting (\(error))")
        case .failed(let error):
            NSLog("ClipStack sync: listener failed (\(error))")
            listener.cancel()
            self.listener = nil
            port = nil
            rebuildPairingLink()
            if case .posix(let code) = error, code == .EADDRINUSE, !triedFallbackPort {
                // 47474 is taken (another copy of ClipStack?): any free port
                // works, Bonjour and the pairing link carry the real one.
                triedFallbackPort = true
                startListener(port: nil)
            } else {
                scheduleRestart()
            }
        default:
            break
        }
    }

    private func scheduleRestart() {
        guard isRunning else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.listener == nil else { return }
                self.triedFallbackPort = false
                self.startListener(port: SyncProtocol.defaultPort)
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// DNS-SD TXT record: length-prefixed "key=value" strings.
    private func txtRecord() -> Data {
        let entries = [
            ("v", "1"),
            ("id", identity.deviceId),
            ("name", localDevice.name),
            ("pf", SyncProtocol.platform),
        ]
        var data = Data()
        for (key, value) in entries {
            var entry = Data("\(key)=\(value)".utf8)
            if entry.count > 255 { entry = entry.prefix(255) }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }

    private func accept(_ connection: NWConnection) {
        guard isRunning, sessions.count < Self.maxSessions else {
            connection.cancel()
            return
        }
        let session = SyncSession(
            connection: connection,
            staticKey: identity.privateKey,
            localDevice: localDevice,
            appVersion: appVersion
        )
        session.delegate = self
        sessions.append(session)
        session.start()
    }

    // MARK: - Pairing window

    /// Opens (or renews) the pairing window shown as a QR code.
    func openPairingWindow() {
        guard isRunning else { return }
        justPairedName = nil
        var token = Data(count: 16)
        let status = token.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { return }
        pairingToken = token
        isPairingOpen = true
        pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)

        pairingTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pairingLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pairingWindowExpired()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pairingTimer = timer
        NSLog("ClipStack sync: pairing window open")
        rebuildPairingLink()
    }

    func closePairingWindow() {
        pairingTimer?.invalidate()
        pairingTimer = nil
        pairingToken = nil
        isPairingOpen = false
        pairingExpiresAt = nil
        rebuildPairingLink()
    }

    private func pairingWindowExpired() {
        NSLog("ClipStack sync: pairing code expired")
        if keepPairingOpen {
            openPairingWindow()
        } else {
            closePairingWindow()
        }
    }

    private func rebuildPairingLink() {
        var link: String?
        if let token = pairingToken, let port {
            let device = localDevice
            let query: [(String, String)] = [
                ("v", "1"),
                ("id", device.id),
                ("name", device.name),
                ("pf", device.platform),
                ("pk", identity.publicKey.base64URLEncoded),
                ("token", token.base64URLEncoded),
                ("port", String(port)),
                ("hosts", Self.localIPv4Addresses().joined(separator: ",")),
            ]
            link = "clipstack://pair?" + query
                .map { "\($0.0)=\(Self.percentEncode($0.1))" }
                .joined(separator: "&")
        }
        guard link != pairingLink else { return }
        pairingLink = link
        onPairingLinkChanged?(link)
    }

    /// RFC 3986 unreserved characters stay as-is; everything else (spaces,
    /// apostrophes in "Zaman's MacBook", commas between hosts) is encoded.
    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // .alphanumerics includes non-ASCII letters; restrict to ASCII.
        return value.unicodeScalars.map { scalar -> String in
            if scalar.isASCII, allowed.contains(scalar) { return String(scalar) }
            return String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    /// Non-loopback, non-link-local IPv4 addresses of interfaces that are up;
    /// Wi-Fi/Ethernet (en*) first so phones try the likely one first. VM and
    /// container bridges (Docker, OrbStack, emulators) are left out: a phone
    /// can never reach them and would waste a connection attempt on each.
    static func localIPv4Addresses() -> [String] {
        var found: [(interface: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            let interface = String(cString: entry.pointee.ifa_name)
            guard !ip.hasPrefix("169.254."),
                  !["bridge", "vmnet", "vmenet"].contains(where: { interface.hasPrefix($0) })
            else { continue }
            found.append((interface, ip))
        }

        var seen = Set<String>()
        return found
            .sorted { ($0.interface.hasPrefix("en") ? 0 : 1, $0.interface) < ($1.interface.hasPrefix("en") ? 0 : 1, $1.interface) }
            .map(\.address)
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Devices

    private func reloadDevices() {
        pairedDevices = (try? database.pairedDevices()) ?? []
    }

    /// Forget a device; tell it first if it's connected.
    func removeDevice(id: String) {
        if let session = activeSessions[id] {
            session.sendAndClose(SyncMessage(type: "unpair"))
        }
        for session in sessions where session.peer?.id == id && session !== activeSessions[id] {
            session.close()
        }
        try? database.deletePairedDevice(id: id)
        reloadDevices()
        NSLog("ClipStack sync: removed device \(id)")
    }

    // MARK: - Sending

    /// Send a local copy to every connected device. Only called for clipboard
    /// watcher captures — received clips are never forwarded (spec rule 1).
    /// Last queued send; each broadcast waits for it, so clips leave in copy
    /// order even when an earlier one (a big photo) takes longer to prepare.
    private var broadcastTail: Task<Void, Never>?

    func broadcast(_ clip: Clip) {
        guard isRunning, !activeSessions.isEmpty else { return }
        let origin = identity.deviceId
        let previous = broadcastTail
        broadcastTail = Task { [weak self] in
            // Reading and converting images happens off the main thread.
            let message = await Task.detached(priority: .userInitiated) {
                Self.message(for: clip, origin: origin)
            }.value
            await previous?.value
            guard let self, let message else { return }
            for (deviceId, session) in self.activeSessions where session.isReady {
                session.send(message)
                NSLog("ClipStack sync: sent \(message.string("kind") ?? "?") clip (\(message.body.count) B body) to \(deviceId)")
            }
        }
    }

    nonisolated private static func message(for clip: Clip, origin: String) -> SyncMessage? {
        var fields: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "origin": origin,
            "createdAt": Int64(clip.createdAt.timeIntervalSince1970 * 1000),
        ]
        var body = Data()

        switch clip.kind {
        case .text, .url:
            guard let text = clip.textContent else { return nil }
            fields["kind"] = clip.kind == .url ? "url" : "text"
            fields["text"] = text

        case .rtf:
            guard let text = clip.textContent else { return nil }
            fields["text"] = text
            if let path = clip.dataPath,
               let rtf = try? Data(contentsOf: URL(fileURLWithPath: path)),
               rtf.count <= SyncProtocol.maxBodyLength
            {
                fields["kind"] = "rtf"
                fields["mime"] = "text/rtf"
                body = rtf
            } else {
                fields["kind"] = "text" // formatting too big or missing: plain text still syncs
            }

        case .image:
            guard let path = clip.dataPath,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let png = pngData(from: data, path: path),
                  png.count <= SyncProtocol.maxBodyLength
            else { return nil }
            fields["kind"] = "image"
            fields["mime"] = "image/png"
            body = png

        case .file:
            // A Finder copy puts the file's path on the clipboard, not its
            // pixels, and a Mac path means nothing on a phone (spec: v1 skips
            // files). A single picture is the exception: send the picture.
            guard let png = imageFileAsPNG(clip.fileURLs) else { return nil }
            fields["kind"] = "image"
            fields["mime"] = "image/png"
            body = png

        case .color:
            return nil
        }
        return SyncMessage(type: "clip", fields: fields, body: body)
    }

    /// A copied image file (JPEG, HEIC, PNG…) as PNG within the protocol's body
    /// limit: full size when it fits, otherwise scaled down step by step.
    /// Nil for anything but exactly one image file.
    nonisolated private static func imageFileAsPNG(_ urls: [URL]) -> Data? {
        guard urls.count == 1, let url = urls.first,
              let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        for maxSide in [8192, 4096, 3072, 2048, 1536] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, // honour EXIF rotation
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if data.length <= SyncProtocol.maxBodyLength { return data as Data }
        }
        return nil
    }

    /// The spec only carries PNG; images captured as TIFF are converted.
    nonisolated private static func pngData(from data: Data, path: String) -> Data? {
        if path.hasSuffix(".png") { return data }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Receiving

    private func applyRemoteClip(_ message: SyncMessage, from device: SyncDevice) {
        guard let clipId = message.string("id"), !clipId.isEmpty else { return }
        guard !receivedIdSet.contains(clipId) else { return }
        receivedIds.append(clipId)
        receivedIdSet.insert(clipId)
        if receivedIds.count > 200 {
            receivedIdSet.remove(receivedIds.removeFirst())
        }

        let now = Date()
        func clip(kind: ClipKind, text: String?, hash: String, byteSize: Int) -> Clip {
            Clip(
                id: UUID().uuidString,
                kind: kind,
                textContent: text,
                dataPath: nil,
                previewPath: nil,
                contentHash: hash,
                // No source app on another device: a device marker gets a
                // phone/computer badge in the overlay instead of a blank icon.
                sourceBundle: AppIconProvider.deviceBundle(forPlatform: device.platform),
                sourceName: device.name,
                byteSize: byteSize,
                createdAt: now,
                lastUsedAt: now,
                pinboardId: nil
            )
        }

        let kind = message.string("kind") ?? ""
        var record: Clip?
        var storeInHistory = true
        let pasteboard = AppPasteboard.shared

        switch kind {
        case "text", "url":
            guard let text = message.string("text"), !text.isEmpty else { return }
            record = clip(kind: kind == "url" ? .url : .text, text: text,
                          hash: BlobStore.sha256("text:" + text), byteSize: text.utf8.count)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)

        case "rtf":
            guard let text = message.string("text") else { return }
            let hash = BlobStore.sha256("text:" + text)
            var rich = clip(kind: .text, text: text, hash: hash, byteSize: text.utf8.count)
            pasteboard.clearContents()
            if !message.body.isEmpty {
                pasteboard.setData(message.body, forType: .rtf)
                if let path = try? BlobStore.writeBlob(message.body, hash: hash, fileExtension: "rtf") {
                    rich.kind = .rtf
                    rich.dataPath = path
                }
            }
            pasteboard.setString(text, forType: .string)
            record = rich

        case "image":
            let png = message.body
            guard !png.isEmpty, NSImage(data: png) != nil else { return }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            // The clipboard always gets the image; history follows the
            // user's capture settings like a local copy would.
            storeInHistory = settings.captureImages
                && (settings.maxItemBytes == 0 || png.count <= settings.maxItemBytes)
            if storeInHistory {
                let hash = BlobStore.sha256(png)
                var image = clip(kind: .image, text: nil, hash: hash, byteSize: png.count)
                image.dataPath = try? BlobStore.writeBlob(png, hash: hash, fileExtension: "png")
                image.previewPath = BlobStore.writeThumbnail(for: png, hash: hash)
                record = image.dataPath == nil ? nil : image
            }

        default:
            NSLog("ClipStack sync: ignoring clip of unknown kind \(kind)")
            return
        }

        // Our own write: the watcher must not capture (and re-send) it.
        pasteboard.setString("1", forType: ClipboardWatcher.selfWriteType)
        NSLog("ClipStack sync: received \(kind) clip (\(message.body.count) B body) from \(device.name)")

        guard storeInHistory, let record else { return }
        do {
            try database.ingest(record)
            var evicted = try database.enforceLimit(settings.historyLimit)
            evicted += try database.enforceRetention(seconds: settings.retentionSeconds)
            BlobStore.deleteFiles(for: evicted, database: database)
        } catch {
            NSLog("ClipStack sync: storing received clip failed: \(error)")
        }
    }
}

// MARK: - SyncSessionDelegate

extension SyncService: SyncSessionDelegate {
    func session(_ session: SyncSession, admit deviceId: String, staticKey: Data) -> SyncSession.Admission {
        if let device = pairedDevices.first(where: { $0.id == deviceId }), device.publicKey == staticKey {
            return .paired
        }
        return pairingToken != nil ? .pairingOnly : .reject
    }

    func session(_ session: SyncSession, pairWithToken token: Data, device: SyncDevice, staticKey: Data) -> Bool {
        guard let expected = pairingToken, Self.constantTimeEqual(token, expected) else { return false }
        let now = Date()
        let record = PairedDevice(
            id: device.id,
            name: device.name,
            platform: device.platform,
            publicKey: staticKey,
            pairedAt: now,
            lastSeenAt: now
        )
        do {
            try database.savePairedDevice(record)
        } catch {
            NSLog("ClipStack sync: saving paired device failed: \(error)")
            return false
        }
        reloadDevices()
        NSLog("ClipStack sync: paired with \(device.name) (\(device.platform))")

        // Single use: the code is spent.
        closePairingWindow()
        justPairedName = device.name
        if keepPairingOpen {
            openPairingWindow()
        }
        return true
    }

    func sessionBecameReady(_ session: SyncSession, device: SyncDevice) {
        // A newer session replaces an older one with the same device.
        if let old = activeSessions[device.id], old !== session {
            old.close()
        }
        activeSessions[device.id] = session
        onlineDeviceIds.insert(device.id)
        try? database.touchPairedDevice(id: device.id, name: device.name, platform: device.platform)
        reloadDevices()
    }

    func session(_ session: SyncSession, didReceive message: SyncMessage) {
        guard let device = session.peer else { return }
        switch message.type {
        case "clip":
            applyRemoteClip(message, from: device)
        case "unpair":
            NSLog("ClipStack sync: \(device.name) removed this pairing")
            try? database.deletePairedDevice(id: device.id)
            reloadDevices()
            session.close()
        default:
            break // unknown types are ignored (forward compatibility)
        }
    }

    func sessionDidClose(_ session: SyncSession) {
        sessions.removeAll { $0 === session }
        guard let id = session.peer?.id, activeSessions[id] === session else { return }
        activeSessions[id] = nil
        onlineDeviceIds.remove(id)
        try? database.touchPairedDevice(id: id, name: nil, platform: nil)
        reloadDevices()
        NSLog("ClipStack sync: \(session.peer?.name ?? id) disconnected")
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}
