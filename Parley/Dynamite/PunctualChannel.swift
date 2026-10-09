import Foundation
import os
import SwiftProtobuf

enum PunctualError: Error { case unregistered, malformed, watchFailed(Int), renew }

/// Google Chat's realtime channel ("Punctual"): a multi-watch WebChannel on the user's event stream plus one typing
/// watch per open conversation, reconnecting until cancelled. Each reconnect resumes the stream from its last watermark.
actor PunctualChannel {
    struct Config: Sendable {
        var backoff: @Sendable (Int) -> Duration = PunctualChannel.backoff
        /// Google Chat refreshes the channel's credentials every 240–280 s.
        var refresh: @Sendable () -> Duration = { .milliseconds(Int.random(in: 240_000...280_000)) }
        // ponytail: a new registration by reopening at half the lease, instead of Google Chat's api/heartbeat; add that if reopening ever drops events.
        var renewAfter: @Sendable (Int) -> Duration = { .seconds($0 / 2) }
    }

    private let authorizer: WebSessionAuthorizer
    private let config: Config
    private let onEvent: @Sendable (Dynamite_Event) async -> Void
    private let onState: @Sendable (ConnectionState) async -> Void
    private let log = Logger(subsystem: "dev.cuza.Parley", category: "punctual")
    // Outlive sessions.
    private var registration: PunctualWire.Registration?
    private var userStart: Int64?            // last watermark of the user stream
    private var typing: [String: Int] = [:]  // group id → watch id
    private var nextID = 2                   // 1 is the user stream
    private var sessions = 0
    private var backoffSleep: Task<Void, Never>?
    // Per session.
    private var gsession = "", sid = "", channelID: String?
    private var streamType = 1, keepaliveMs = 30_000, aid = 0, rid = 0, offset = 0
    private var connected = false

    init(authorizer: WebSessionAuthorizer, config: Config = Config(),
         onEvent: @escaping @Sendable (Dynamite_Event) async -> Void,
         onState: @escaping @Sendable (ConnectionState) async -> Void) {
        self.authorizer = authorizer; self.config = config; self.onEvent = onEvent; self.onState = onState
    }

    /// Backoff: 1 s doubling to 60 s, ±20 % jitter.
    static func backoff(_ attempt: Int) -> Duration {
        let seconds = min(60, pow(2, Double(max(0, attempt - 1)))) * Double.random(in: 0.8...1.2)
        return .milliseconds(Int(seconds * 1000))
    }
    /// For the log: the failure's kind and code, never a URL or cookie.
    static func reason(_ error: Error) -> String {
        switch error {
        case let channel as WebChannelError: "WebChannelError.\(channel)"
        case let punctual as PunctualError: "PunctualError.\(punctual)"
        case let auth as AuthFailure: "AuthFailure.\(auth)"
        case let url as URLError: "URLError \(url.code.rawValue)"
        default: String(describing: type(of: error))
        }
    }
    /// Network came back or the Mac woke: skip the rest of the current backoff wait.
    func nudge() { backoffSleep?.cancel() }

    /// The conversations whose typing to watch; added and cancelled on a live channel, all re-sent on reconnect.
    func subscribe(_ conversations: Set<ConversationID>) async {
        let wanted = Set(conversations.compactMap { $0.split(separator: "/").last.map(String.init) })
        let added = wanted.subtracting(typing.keys).sorted(), removed = Set(typing.keys).subtracting(wanted)
        let cancelled = removed.compactMap { typing.removeValue(forKey: $0) }
        let watches = added.map { group in
            defer { nextID += 1 }
            typing[group] = nextID
            return PunctualWire.Watch(id: nextID, target: .typing(group), start: nil, resumed: false, reason: 1)
        }
        guard connected else { return }
        do {
            if !watches.isEmpty { try await send(PunctualWire.batch(watches, streamType: streamType)) }
            if !cancelled.isEmpty { try await send(PunctualWire.cancel(cancelled.sorted())) }
        } catch { log.error("Typing watch update failed: \(Self.reason(error), privacy: .public)") }
    }

    func run() async {
        var failures = 0
        while !Task.isCancelled {
            let opened = ContinuousClock.now
            do {
                try await openSession()
                let lease = registration?.leaseSeconds ?? 3600
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.pollLoop() }
                    group.addTask { try await self.refreshLoop() }
                    group.addTask { try await Task.sleep(for: self.config.renewAfter(lease)); throw PunctualError.renew }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch where (error as? AuthFailure)?.endsSession == true {
                await onState(.signedOut)
                return
            } catch PunctualError.renew {
                log.notice("Punctual: reopening with a new registration")
                continue
            } catch {
                log.error("Punctual session ended: \(Self.reason(error), privacy: .public)")
            }
            if Task.isCancelled { return }
            failures = connected && opened.duration(to: .now) >= .seconds(30) ? 1 : failures + 1
            connected = false
            await onState(.reconnecting)
            let sleep = Task { [delay = config.backoff(failures)] in _ = try? await Task.sleep(for: delay) }
            backoffSleep = sleep
            await withTaskCancellationHandler { await sleep.value } onCancel: { sleep.cancel() }
            backoffSleep = nil
        }
    }

    private func openSession() async throws {
        connected = false; channelID = nil; sid = ""; aid = 0; offset = 0
        rid = Int.random(in: 10_000..<90_000)
        let first = sessions == 0
        sessions += 1
        guard let json = try await authorizer.punctualRegistration(fresh: !first), let fresh = PunctualWire.Registration(json) else {
            throw PunctualError.unregistered
        }
        if fresh.utid != registration?.utid { userStart = nil }
        registration = fresh
        let reason = first ? 1 : 3
        let user = PunctualWire.Watch(id: 1, target: .user(fresh.utid), start: userStart ?? fresh.startMicros, resumed: userStart != nil, reason: reason)
        let watches = [user] + typing.sorted { $0.value < $1.value }.map {
            PunctualWire.Watch(id: $0.value, target: .typing($0.key), start: nil, resumed: false, reason: reason)
        }

        var choose = URLRequest(url: url("v1/chooseServer", ["key": fresh.apiKey]))
        choose.httpMethod = "POST"
        choose.httpBody = Data(PunctualWire.chooseServer(user).utf8)
        choose.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
        let (chosen, _) = try await authorizer.data(for: choose)
        guard let server = PunctualWire.ChooseServerReply(chosen) else { throw PunctualError.malformed }
        gsession = server.session; streamType = server.streamType
        if first, server.delayMs > 0 { try await Task.sleep(for: .milliseconds(min(server.delayMs, 30_000))) }

        var open = URLRequest(url: channelURL(["RID": String(rid), "CVER": "22", "t": "1"]))
        open.httpMethod = "POST"
        open.httpBody = PunctualWire.forwardBody([PunctualWire.batch(watches, streamType: streamType)], offset: 0)
        offset = 1
        open.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        open.setValue("application/json+protobuf", forHTTPHeaderField: "X-WebChannel-Content-Type")
        let (body, _) = try await authorizer.data(for: open)
        guard let handshake = WebChannelWire.handshake(body: Array(body)) else { throw PunctualError.malformed }
        sid = handshake.sid; keepaliveMs = handshake.keepaliveMs
    }

    private func pollLoop() async throws {
        while true {
            var request = URLRequest(url: channelURL(["RID": "rpc", "SID": sid, "AID": String(aid), "CI": "0", "TYPE": "xmlhttp", "t": "1"]))
            request.timeoutInterval = Double(keepaliveMs) * 1.5 / 1000   // watermarks come every ~20 s
            let (stream, _) = try await authorizer.bytes(for: request)
            var reader = WebChannelWire.FrameReader()
            var frames = 0
            for try await byte in stream {
                for frame in try reader.feed(byte) { frames += 1; try await handle(frame) }
            }
            guard frames > 0 else { throw PunctualError.malformed }   // an empty long poll would loop at network speed
        }
    }

    private func handle(_ frame: WebChannelWire.Frame) async throws {
        aid = max(aid, frame.aid)
        switch frame.payload {
        case .stop, .close: throw WebChannelError.stopped
        case .json(let data):
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [Any], let batch = body.first as? [Any] else { return }
            for update in PunctualWire.updates(batch) { try await apply(update) }
        case .noop, .handshake, .other: break
        }
    }

    private func apply(_ update: PunctualWire.Update) async throws {
        switch update {
        case .channel(let id): channelID = id
        case .started(watch: 1, _):
            guard !connected else { return }
            connected = true
            log.notice("Punctual: user stream started")
            await onState(.connected)
            // Google Chat catches up after every reconnect; the backend does that on SESSION_READY.
            await onEvent(.with { $0.bodies = [.with { $0.eventType = .sessionReady }] })
        case .started: break
        case .watermark(watch: 1, let time): userStart = max(userStart ?? 0, time)
        case .watermark: break
        case .change(_, let payload):
            guard let event = try? Dynamite_Event(serializedBytes: payload) else { log.error("Skipped undecodable Punctual change"); return }
            await onEvent(event)
        case .failed(watch: 1, let code):
            userStart = nil   // a resume point the server no longer keeps; catch-up covers the gap
            throw PunctualError.watchFailed(code)
        case .failed(let watch, let code):
            log.error("Punctual watch \(watch, privacy: .public) failed: \(code, privacy: .public)")
            if let group = typing.first(where: { $0.value == watch })?.key { typing[group] = nil }
        case .close: throw WebChannelError.stopped
        }
    }

    private func refreshLoop() async throws {
        while true {
            try await Task.sleep(for: config.refresh())
            guard let channelID, let registration else { continue }
            var request = URLRequest(url: url("v1/refreshCreds", ["key": registration.apiKey, "gsessionid": gsession]))
            request.httpMethod = "POST"
            request.httpBody = Data(#"["\#(channelID)"]"#.utf8)
            request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
            do { _ = try await authorizer.data(for: request) } catch { log.error("Punctual refreshCreds failed: \(Self.reason(error), privacy: .public)") }
        }
    }

    private func send(_ map: String) async throws {
        rid += 1
        var post = URLRequest(url: channelURL(["SID": sid, "RID": String(rid), "AID": String(aid), "t": "1"]))
        post.httpMethod = "POST"
        post.httpBody = PunctualWire.forwardBody([map], offset: offset)
        offset += 1
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.setValue("application/json+protobuf", forHTTPHeaderField: "X-WebChannel-Content-Type")
        _ = try await authorizer.data(for: post)
    }

    private func channelURL(_ query: KeyValuePairs<String, String>) -> URL {
        url("multi-watch/channel", [("VER", "8"), ("gsessionid", gsession), ("key", registration?.apiKey ?? "")] + query.map { ($0.key, $0.value) })
    }
    private func url(_ path: String, _ query: KeyValuePairs<String, String>) -> URL { url(path, query.map { ($0.key, $0.value) }) }
    private func url(_ path: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(url: registration!.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }
}
