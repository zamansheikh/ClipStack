import CryptoKit
import Foundation
import Network

@MainActor
protocol SyncSessionDelegate: AnyObject {
    /// Frame 1 arrived: may this (device id, static key) continue?
    func session(_ session: SyncSession, admit deviceId: String, staticKey: Data) -> SyncSession.Admission
    /// A `pair` message: true if the token is the open pairing window's.
    func session(_ session: SyncSession, pairWithToken token: Data, device: SyncDevice, staticKey: Data) -> Bool
    /// `hello`/`pair` accepted; the session can carry clips now.
    func sessionBecameReady(_ session: SyncSession, device: SyncDevice)
    /// Any message after the session is ready, except ping/pong/error.
    func session(_ session: SyncSession, didReceive message: SyncMessage)
    func sessionDidClose(_ session: SyncSession)
}

/// One TCP connection from a peer, in the responder role (the Mac listens).
/// Runs the v1 handshake, then exchanges encrypted, length-prefixed frames.
/// Everything runs on the main queue: clipboard traffic is tiny and this
/// keeps the session state free of locking.
@MainActor
final class SyncSession {
    enum Admission {
        /// Known device with a matching key: expects `hello` (or `pair`).
        case paired
        /// Unknown device while the pairing window is open: expects `pair`.
        case pairingOnly
        case reject
    }

    private enum State {
        case awaitingInitiatorHello
        case awaitingFirstMessage(Admission)
        case ready
        case closed
    }

    let connection: NWConnection
    weak var delegate: SyncSessionDelegate?

    /// Set once `hello`/`pair` is accepted.
    private(set) var peer: SyncDevice?
    private(set) var peerStaticKey: Data?
    private var claimedDeviceId: String?

    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let localDevice: SyncDevice
    private let appVersion: String

    private var state: State = .awaitingInitiatorHello
    private var sendCipher: SyncCipher?
    private var receiveCipher: SyncCipher?
    private var lastReceived = Date()
    private var lastPingSent = Date.distantPast
    private var keepAliveTimer: Timer?
    private let openedAt = Date()

    /// Spec keep-alive: ping after 25 s of silence, give up after 60 s.
    private static let pingAfter: TimeInterval = 25
    private static let closeAfter: TimeInterval = 60
    /// A peer that hasn't finished the handshake by then is dropped.
    private static let handshakeTimeout: TimeInterval = 10

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var endpointDescription: String { "\(connection.endpoint)" }

    init(
        connection: NWConnection,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        localDevice: SyncDevice,
        appVersion: String
    ) {
        self.connection = connection
        self.staticKey = staticKey
        self.localDevice = localDevice
        self.appVersion = appVersion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                self?.connectionStateChanged(state)
            }
        }
        connection.start(queue: .main)

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepAliveTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    func close() {
        if case .closed = state { return }
        state = .closed
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        delegate?.sessionDidClose(self)
    }

    /// Encrypt and send a message. Ignored unless the handshake is done.
    func send(_ message: SyncMessage, completion: (() -> Void)? = nil) {
        guard var cipher = sendCipher else { return }
        if case .closed = state { return }
        do {
            let sealed = try cipher.seal(try message.encoded())
            sendCipher = cipher
            sendFrame(sealed, completion: completion)
        } catch {
            NSLog("ClipStack sync: encrypt failed (\(error)), closing \(endpointDescription)")
            close()
        }
    }

    /// Send, then close once the bytes have been handed to the network.
    func sendAndClose(_ message: SyncMessage) {
        send(message) { [weak self] in
            self?.close()
        }
        if sendCipher == nil { close() }
    }

    // MARK: - Connection

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            NSLog("ClipStack sync: connection from \(endpointDescription)")
            readFrame()
        case .failed(let error):
            NSLog("ClipStack sync: connection failed (\(error)) \(endpointDescription)")
            close()
        case .cancelled:
            close()
        default:
            break
        }
    }

    private func keepAliveTick() {
        let now = Date()
        switch state {
        case .closed:
            return
        case .ready:
            let idle = now.timeIntervalSince(lastReceived)
            if idle > Self.closeAfter {
                NSLog("ClipStack sync: \(peer?.name ?? "peer") silent for \(Int(idle)) s, closing")
                close()
            } else if idle > Self.pingAfter, now.timeIntervalSince(lastPingSent) > Self.pingAfter {
                lastPingSent = now
                send(SyncMessage(type: "ping"))
            }
        default:
            if now.timeIntervalSince(openedAt) > Self.handshakeTimeout {
                NSLog("ClipStack sync: handshake timed out \(endpointDescription)")
                close()
            }
        }
    }

    // MARK: - Framing (u32 BE length ‖ payload)

    private func readFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard error == nil, let data, data.count == 4 else {
                    if error != nil || isComplete { self.close() }
                    return
                }
                let length = Int(data.readUInt32BE(at: 0))
                guard length <= SyncProtocol.maxFrameLength else {
                    NSLog("ClipStack sync: frame of \(length) bytes exceeds limit, closing")
                    self.close()
                    return
                }
                guard length > 0 else {
                    self.handleFrame(Data())
                    self.continueReading()
                    return
                }
                self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] payload, _, _, error in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard error == nil, let payload, payload.count == length else {
                            self.close()
                            return
                        }
                        self.handleFrame(payload)
                        self.continueReading()
                    }
                }
            }
        }
    }

    private func continueReading() {
        if case .closed = state { return }
        readFrame()
    }

    private func sendFrame(_ payload: Data, completion: (() -> Void)? = nil) {
        var frame = Data(capacity: 4 + payload.count)
        frame.appendUInt32BE(UInt32(payload.count))
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if let error {
                    NSLog("ClipStack sync: send failed (\(error))")
                    self?.close()
                }
                completion?()
            }
        })
    }

    // MARK: - Protocol

    private func handleFrame(_ frame: Data) {
        lastReceived = Date()
        switch state {
        case .awaitingInitiatorHello:
            handleInitiatorHello(frame)
        case .awaitingFirstMessage(let admission):
            guard let message = decrypt(frame) else { return }
            handleFirstMessage(message, admission: admission)
        case .ready:
            guard let message = decrypt(frame) else { return }
            handleReadyMessage(message)
        case .closed:
            break
        }
    }

    private func handleInitiatorHello(_ frame: Data) {
        do {
            let hello = try SyncHandshake.parseInitiatorHello(frame)
            let admission = delegate?.session(self, admit: hello.deviceId, staticKey: hello.staticKey) ?? .reject
            guard admission != .reject else {
                NSLog("ClipStack sync: rejected unknown device \(hello.deviceId) (pairing window closed)")
                close()
                return
            }
            let (frame2, keys) = try SyncHandshake.respond(to: frame, staticKey: staticKey)
            claimedDeviceId = hello.deviceId
            peerStaticKey = hello.staticKey
            sendCipher = SyncCipher(key: keys.responderToInitiator)
            receiveCipher = SyncCipher(key: keys.initiatorToResponder)
            state = .awaitingFirstMessage(admission)
            sendFrame(frame2)
        } catch {
            NSLog("ClipStack sync: handshake failed (\(error)) \(endpointDescription)")
            close()
        }
    }

    private func decrypt(_ frame: Data) -> SyncMessage? {
        guard var cipher = receiveCipher else {
            close()
            return nil
        }
        do {
            let plaintext = try cipher.open(frame)
            receiveCipher = cipher
            return try SyncMessage.decode(plaintext)
        } catch {
            // Wrong keys (impostor or stale pairing) or a corrupted stream.
            NSLog("ClipStack sync: \(error), closing \(endpointDescription)")
            close()
            return nil
        }
    }

    private func handleFirstMessage(_ message: SyncMessage, admission: Admission) {
        guard let claimedDeviceId, let peerStaticKey else {
            close()
            return
        }
        switch message.type {
        case "pair":
            guard let device = SyncDevice(json: message.fields["device"]), device.id == claimedDeviceId else {
                sendError("unsupported", "device id does not match the handshake")
                return
            }
            guard let tokenString = message.string("token"),
                  let token = Data(base64URLEncoded: tokenString),
                  delegate?.session(self, pairWithToken: token, device: device, staticKey: peerStaticKey) == true
            else {
                NSLog("ClipStack sync: pairing rejected for \(device.name): bad or expired token")
                sendError("bad_token", "This pairing code is invalid or expired. Show a new code on the Mac.")
                return
            }
            send(SyncMessage(type: "paired", fields: ["device": localDevice.json]))
            becomeReady(device)

        case "hello":
            guard admission == .paired else {
                NSLog("ClipStack sync: refused hello from unpaired device \(claimedDeviceId)")
                sendError("not_paired", "This device is not paired with this Mac.")
                return
            }
            guard let device = SyncDevice(json: message.fields["device"]), device.id == claimedDeviceId else {
                sendError("unsupported", "device id does not match the handshake")
                return
            }
            send(SyncMessage(type: "hello", fields: ["device": localDevice.json, "app": appVersion]))
            becomeReady(device)

        default:
            sendError("unsupported", "expected hello or pair")
        }
    }

    private func becomeReady(_ device: SyncDevice) {
        peer = device
        state = .ready
        NSLog("ClipStack sync: session ready with \(device.name) (\(device.platform))")
        delegate?.sessionBecameReady(self, device: device)
    }

    private func handleReadyMessage(_ message: SyncMessage) {
        switch message.type {
        case "ping":
            send(SyncMessage(type: "pong"))
        case "pong":
            break
        case "error":
            NSLog("ClipStack sync: peer error \(message.string("code") ?? "?"): \(message.string("message") ?? "")")
            close()
        default:
            delegate?.session(self, didReceive: message)
        }
    }

    private func sendError(_ code: String, _ text: String) {
        sendAndClose(SyncMessage(type: "error", fields: ["code": code, "message": text]))
    }
}
