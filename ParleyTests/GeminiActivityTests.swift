import Foundation
import Testing
@testable import Parley

/// Ask Gemini at work: the status it sends while it works ("Collecting info"), and the steps behind its answer.
extension AuthTests {
    private static func activity(_ state: Int32, _ text: String = "", topic: String = "q1") -> Dynamite_StreamEventsResponse {
        .with { r in
            r.event.groupID.dmID.dmID = "g"
            r.event.bodies = [.with { b in
                b.eventType = .activityIndicatorChanged
                b.activityIndicatorChanged = .with { e in
                    e.state = state; e.userID.id = "gemini"
                    e.context.topicID.topicID = topic; e.context.topicID.groupID.dmID.dmID = "g"
                    if !text.isEmpty { e.progress.text = text }
                }
            }]
        }
    }
    @Test func anAgentsStatusArrivesUntilItStops() async throws {
        let (backend, _) = try await Self.connected()
        await backend.handle(Self.activity(1))
        await backend.handle(Self.activity(1, "Collecting info"))
        await backend.handle(Self.activity(2))
        let events = await Self.drain(backend).filter { if case .activityChanged = $0 { true } else { false } }
        #expect(events == [.activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: "Thinking"),
                           .activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: "Collecting info"),
                           .activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: nil)])
    }
}

@MainActor struct GeminiActivityStoreTests {
    @Test func theComposerLineShowsTheStatusInTheChatAndTheThread() async throws {
        let store = ChatStore(backend: FakeBackend())
        await store.start()
        store.apply(.activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: "Collecting info"))
        #expect(store.activityLine("dm/g", thread: nil, name: "Ask Gemini") == "Ask Gemini · Collecting info…")
        #expect(store.activityLine("dm/g", thread: "dm/g/q1/q1", name: "Ask Gemini") == "Ask Gemini · Collecting info…")
        store.apply(.activityChanged("dm/g", "dm/g/q1/q1", "gemini", label: nil))
        #expect(store.activityLine("dm/g", thread: nil, name: "Ask Gemini") == nil)
    }
}

struct GeminiThinkingTests {
    @Test func anAnswersStepsComeFromItsActivityAnnotation() throws {
        let proto = Dynamite_Message.with { m in
            m.id.messageID = "a1"; m.id.parentID.topicID.topicID = "q1"; m.creator.userID.id = "gemini"; m.textBody = "Langfuse runs on Tadashi."
            m.annotations = [.with { a in
                a.type = .activity
                a.activityMetadata.log.entries = [.with { $0.title = "Searching Chat"; $0.content = "Looked for where it runs." },
                                                  .with { $0.title = "Checking Drive"; $0.content = "Found the infra notes." }]
            }]
        }
        let message = try #require(DynamiteMapper.message(proto, in: "dm/g", selfID: "me", people: [:]))
        #expect(message.thinking == [ThinkingStep(title: "Searching Chat", text: "Looked for where it runs."),
                                     ThinkingStep(title: "Checking Drive", text: "Found the infra notes.")])
        #expect(message.text == "Langfuse runs on Tadashi.")
        let layout = RowLayout.make(TimelineRow.rows([message])[0], width: 600, own: false, kind: .direct)
        let line = try #require(layout.thinking), text = try #require(layout.text)
        #expect(layout.bubble.contains(line) && line.maxY <= text.minY)
    }
}
