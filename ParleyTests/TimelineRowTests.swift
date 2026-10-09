import Foundation
import Testing
@testable import Parley

struct TimelineRowTests {
    private let maria = Person(id: "maria", name: "Maria")
    private let alex = Person(id: "alex", name: "Alex")
    private func message(_ id: String, _ sender: Person, _ seconds: TimeInterval) -> Message {
        Message(id: id, conversationID: "c", sender: sender, text: id, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds))
    }

    @Test func groupsBySenderWithinFiveMinutesAndMarksNewDays() {
        let rows = TimelineRow.rows([
            message("a", maria, 0), message("b", maria, 60),     // same run
            message("c", maria, 60 + 300),                       // 5 min gap: new run
            message("d", alex, 400),                             // sender change
            message("e", alex, 400 + 86_400)                     // next day
        ])
        #expect(rows.map(\.begins) == [true, false, true, true, true])
        #expect(rows.map(\.ends) == [false, true, true, true, true])
        #expect(rows.map(\.newDay) == [true, false, false, false, true])
    }
    @Test func rowsAreSelfContained() {
        #expect(TimelineRow.rows([]).isEmpty)
        let single = TimelineRow.rows([message("a", maria, 0)])
        #expect(single.count == 1 && single[0].begins && single[0].ends && single[0].newDay)
    }
}
