import Foundation
import Testing
@testable import Parley

struct WebChannelWireTests {
    private func frame(_ json: String) -> [UInt8] { Array("\(json.utf16.count)\n\(json)".utf8) }

    @Test func framesSplitAcrossReadsAreReassembled() throws {
        let all = frame(#"[[1,["noop"]]]"#) + frame(#"[[2,["close"]]]"#)
        var buffer = Array(all[..<10])
        #expect(try WebChannelWire.takeFrames(&buffer).isEmpty)
        buffer += all[10...]
        #expect(try WebChannelWire.takeFrames(&buffer) == [.init(aid: 1, payload: .noop), .init(aid: 2, payload: .close)])
        #expect(buffer.isEmpty)
    }
    @Test func lengthCountsUTF16UnitsNotBytes() throws {
        var buffer = frame(#"[[3,["é😀"]]]"#) + frame(#"[[4,["stop"]]]"#)   // é: 1 unit/2 bytes, 😀: 2 units/4 bytes
        #expect(try WebChannelWire.takeFrames(&buffer).map(\.payload) == [.other, .stop])
    }
    @Test func malformedLengthThrows() {
        var buffer = Array("abc\n[]".utf8)
        #expect(throws: WebChannelError.malformed) { try WebChannelWire.takeFrames(&buffer) }
    }
    @Test func handshakeFromHeaderPrefixedBodyOrRawBody() {
        let json = #"[[0,["c","SID1","",8,12,20000]]]"#
        let expected = WebChannelWire.Handshake(sid: "SID1", keepaliveMs: 20000)
        #expect(WebChannelWire.handshake(body: frame(json)) == expected)
        #expect(WebChannelWire.handshake(body: Array(json.utf8)) == expected)
        #expect(WebChannelWire.handshake(body: Array(json.utf8.prefix(10))) == nil)
    }
    @Test func readerYieldsFrameWhoseLengthCountsTrailingNewline() throws {
        let json = #"[[7,["noop"]]]"#
        var reader = WebChannelWire.FrameReader()
        var frames: [WebChannelWire.Frame] = []
        for byte in Array("\(json.utf16.count + 1)\n\(json)\n".utf8) { frames += try reader.feed(byte) }
        #expect(frames == [.init(aid: 7, payload: .noop)])
    }
}
