import Foundation
import SwiftProtobuf
import Testing
@testable import Parley

struct PunctualWireTests {
    static let block = #"["dfe.cr.rr",["reg-1"],[null,[null,"/punctual/prod-dynamite-prod-02-us/user-targeted-changes",["","user-state-changes","group-state-changes"]],[1791432459,227491000],[3600],"utid1","key1"],1]"#

    @Test func registrationComesFromThePage() throws {
        let page = #"<script>var x = {"a":"]"}; foo(["other",[1]]); bar("x]["); AF(\#(Self.block));</script>"#
        let json = try #require(PunctualWire.registrationBlock(in: page))
        let registration = try #require(PunctualWire.Registration(json))
        #expect(registration.baseURL.absoluteString == "https://chat.google.com/punctual/prod-02-us")
        #expect(registration.startMicros == 1_791_432_459_227_491)
        #expect(registration.leaseSeconds == 3600)
        #expect(registration.utid == "utid1")
        #expect(registration.apiKey == "key1")
        #expect(PunctualWire.registrationBlock(in: "<html>no block</html>") == nil)
    }
    @Test func unknownEnvironmentIsRejected() {
        #expect(PunctualWire.Registration(Self.block.replacingOccurrences(of: "prod-dynamite-prod-02-us", with: "staging-x")) == nil)
    }
    @Test func sapisidHashIsGooglesStandardForm() {
        let cookies = [SessionCookie(name: "SAPISID", value: "abc", domain: ".google.com", path: "/", secure: true, expires: -1)]
        #expect(WebSessionAuthorizer.sapisidHash(cookies, at: Date(timeIntervalSince1970: 1_700_000_000))
                == "SAPISIDHASH 1700000000_c37cbcfc4f485638947ca5e102cc6ae5eb0710df")
        #expect(WebSessionAuthorizer.sapisidHash([], at: .now) == nil)
    }
    @Test func requestsMatchGoogleChatsBytes() {
        let user = PunctualWire.Watch(id: 1, target: .user("U"), start: 5, resumed: false, reason: 1)
        #expect(PunctualWire.chooseServer(user) ==
                #"[[null,null,null,[9,5],null,[["user-targeted-changes"],[null,1],[[["userTargeted"],["U"],["events"]]]]],null,null,0,0]"#)
        let typing = PunctualWire.Watch(id: 2, target: .typing("G"), start: nil, resumed: false, reason: 1)
        #expect(PunctualWire.batch([user, typing], streamType: 1) ==
                #"[[[1,[5,null,null,[9,5],null,[["user-targeted-changes"],[null,1],[[["userTargeted"],["U"],["events"]]]],null,0,1],null,1],"#
                + #"[2,[null,null,null,[9,5],null,[["group-state-changes"],[1],[[["state"],["group"],["G"],["typing"]]]],null,0,1],null,1]]]"#)
        #expect(PunctualWire.cancel([7]) == "[[[7,null,[]]]]")
        #expect(PunctualWire.ChooseServerReply(Data(#"["G1",1,null,"10","20"]"#.utf8)) == .init(session: "G1", streamType: 1, delayMs: 0))
    }
    @Test func serverFramesDecode() throws {
        let event = Dynamite_Event.with { $0.userRevision.timestamp = 42 }
        let base64 = (try event.serializedBytes() as Data).base64EncodedString()
        #expect(PunctualWire.updates(#"[null,null,["ch1"]]"#) == [.channel("ch1")])
        #expect(PunctualWire.updates(#"[[["1",[["100"]]]]]"#) == [.started(watch: 1, at: 100)])
        #expect(PunctualWire.updates(#"[[["2",[null,null,["300"]]],["1",[null,null,["300"]]]]]"#)
                == [.watermark(watch: 2, at: 300), .watermark(watch: 1, at: 300)])
        #expect(PunctualWire.updates(#"[[["1",[null,[[[null,"\#(base64)","9",null,null,[]]]]]]]]"#)
                == [.change(watch: 1, payload: try event.serializedBytes())])
        #expect(PunctualWire.updates(#"[[["1",null,[[14,null,"busy"]]]]]"#) == [.failed(watch: 1, code: 14)])
        #expect(PunctualWire.updates(#"[null,[1]]"#) == [.close])
    }
}

extension AuthTests {
    private static func frame(_ json: String) -> String { "\(json.utf16.count)\n\(json)" }
    private static let bootstrap = StubExchange.Reply(data: Data((#"{"SMqcke":"test-xsrf"} "# + PunctualWireTests.block).utf8))

    @Test(.timeLimit(.minutes(1))) func punctualChannelDeliversEvents() async throws {
        let vault = MemoryVault()
        let cookies = [SessionCookie(name: "SID", value: "s", domain: ".google.com", path: "/", secure: true, expires: -1),
                       SessionCookie(name: "SAPISID", value: "abc", domain: ".google.com", path: "/", secure: true, expires: -1)]
        vault.write(try JSONEncoder().encode(WebCredentials(cookies: cookies, userAgent: "TestAgent/1")))
        let event = Dynamite_Event.with { $0.userRevision.timestamp = 42 }
        let base64 = (try event.serializedBytes() as Data).base64EncodedString()
        let stream = Self.frame(#"[[1,[[null,null,["ch1"]]]],[2,[[[["1",[["100"]]]]]]]]"#)
            + Self.frame(#"[[3,[[[["1",[null,[[[null,"\#(base64)","9"]]]]]]]]]]"#)
        let exchange = StubExchange([Self.bootstrap,
                                     .init(data: Data(#"["G1",1,null,"10","20"]"#.utf8)),
                                     .init(data: Data(Self.frame(#"[[0,["c","SID1","",8,15,30000]]]"#).utf8)),
                                     .init(data: Data(stream.utf8))])
        let auth = WebSessionAuthorizer(vault: vault, session: AuthStubProtocol.session(exchange))
        let (received, sink) = AsyncStream<Dynamite_Event>.makeStream()
        let (states, stateSink) = AsyncStream<ConnectionState>.makeStream()
        let channel = PunctualChannel(authorizer: auth, onEvent: { sink.yield($0) }, onState: { stateSink.yield($0) })
        let run = Task { await channel.run() }
        var events = received.makeAsyncIterator()
        let ready = await events.next()
        let pushed = await events.next()
        var stateIterator = states.makeAsyncIterator()
        let state = await stateIterator.next()
        run.cancel(); await run.value
        #expect(ready?.bodies.first?.eventType == .sessionReady)
        #expect(pushed?.userRevision.timestamp == 42)
        #expect(state == .connected)
        let requests = exchange.requests
        let choose = requests[1]
        #expect(choose.url?.absoluteString == "https://chat.google.com/punctual/prod-02-us/v1/chooseServer?key=key1")
        #expect(choose.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        #expect(choose.value(forHTTPHeaderField: "X-Goog-AuthUser") == "0")
        let open = requests[2]
        #expect(open.url?.path == "/punctual/prod-02-us/multi-watch/channel")
        #expect(open.url?.query?.contains("gsessionid=G1") == true)
        #expect(open.url?.query?.contains("TYPE=init") == false)
        #expect(open.value(forHTTPHeaderField: "X-WebChannel-Content-Type") == "application/json+protobuf")
        let poll = requests[3]
        #expect(poll.httpMethod == "GET")
        #expect(poll.url?.query?.contains("SID=SID1") == true)
    }
}
