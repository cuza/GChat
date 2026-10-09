import AppKit
import Testing
@testable import Parley

struct ReplySwipeTests {
    /// Feeds `steps` changes of `delta` and returns their outcomes.
    private func move(_ swipe: inout ReplySwipe, _ steps: Int, by delta: CGFloat, width: CGFloat = 600) -> [ReplySwipe.Outcome] {
        (0..<steps).map { _ in swipe.handle(.changed, towardReply: delta, vertical: 0, width: width) }
    }
    private func stage(_ outcome: ReplySwipe.Outcome?) -> ReplySwipe.Stage? {
        if case let .moved(_, stage, _) = outcome { stage } else { nil }
    }
    private func crossings(_ outcomes: [ReplySwipe.Outcome]) -> Int {
        outcomes.filter { if case .moved(_, _, true) = $0 { true } else { false } }.count
    }

    @Test func verticalScrollingIsNeverASwipe() {
        var swipe = ReplySwipe()
        #expect(swipe.handle(.began, towardReply: 0, vertical: 6, width: 600) == .ignore)
        #expect(swipe.handle(.changed, towardReply: 30, vertical: 6, width: 600) == .ignore)
        #expect(swipe.handle(.ended, towardReply: 0, vertical: 0, width: 600) == .ignore)
    }
    @Test func pastTheFirstThresholdItArmsQuoteOnceAndCommitsIt() {
        var swipe = ReplySwipe()
        #expect(swipe.handle(.began, towardReply: 4, vertical: 0, width: 600) == .began)
        let outcomes = move(&swipe, 12, by: 12)   // 144 pt: between the thresholds
        let offsets = outcomes.compactMap { if case let .moved(offset, _, _) = $0 { offset } else { nil } }
        #expect(offsets.count == 12 && zip(offsets, offsets.dropFirst()).allSatisfy { $0 >= $1 })   // the row slides left
        #expect(crossings(outcomes) == 1 && stage(outcomes.last) == .quote)
        #expect(swipe.handle(.ended, towardReply: 0, vertical: 0, width: 600) == .committed(.quote))
    }
    @Test func swipingFurtherSwitchesToThreadAndBackingOffReturnsToQuote() {
        var swipe = ReplySwipe()
        _ = swipe.handle(.began, towardReply: 4, vertical: 0, width: 600)
        let out = move(&swipe, 9, by: 12)                                   // 108: quote
        #expect(stage(out.last) == .quote && crossings(out) == 1)
        let further = move(&swipe, 8, by: 12)                               // 204: thread
        #expect(stage(further.last) == .thread && crossings(further) == 1)
        let back = move(&swipe, 3, by: -12)                                 // 168: quote again
        #expect(stage(back.last) == .quote && crossings(back) == 1)
        _ = move(&swipe, 3, by: 12)                                         // 204: thread
        #expect(swipe.handle(.ended, towardReply: 0, vertical: 0, width: 600) == .committed(.thread))
    }
    @Test func theThreadStageIsReachableAtTypicalRowWidths() {
        for width: CGFloat in [300, 400, 600, 900] {
            var swipe = ReplySwipe()
            _ = swipe.handle(.began, towardReply: 4, vertical: 0, width: width)
            let outcomes = move(&swipe, 40, by: 12, width: width)           // 480 pt of finger travel
            let first = outcomes.firstIndex { stage($0) == .thread }
            #expect(first != nil, "width \(width)")
            if let first, case let .moved(offset, _, _) = outcomes[first] { #expect(-offset >= ReplySwipe.threadThreshold) }
        }
    }
    @Test func withoutThreadsOnlyQuoteApplies() {
        var swipe = ReplySwipe()
        swipe.allowsThread = false
        _ = swipe.handle(.began, towardReply: 4, vertical: 0, width: 600)
        let outcomes = move(&swipe, 30, by: 12)
        #expect(crossings(outcomes) == 1 && outcomes.allSatisfy { stage($0) != .thread })
        #expect(swipe.handle(.ended, towardReply: 0, vertical: 0, width: 600) == .committed(.quote))
    }
    @Test func aShortSwipeSpringsBackAndBackingOffDisarms() {
        var swipe = ReplySwipe()
        _ = swipe.handle(.began, towardReply: 4, vertical: 0, width: 600)
        _ = swipe.handle(.changed, towardReply: 20, vertical: 0, width: 600)
        #expect(swipe.handle(.ended, towardReply: 0, vertical: 0, width: 600) == .cancelled)
        _ = swipe.handle(.began, towardReply: 4, vertical: 0, width: 600)
        _ = move(&swipe, 40, by: 12)
        let back = move(&swipe, 40, by: -12)
        #expect(stage(back.last) == nil && crossings(back) == 2)   // thread → quote → nothing
        #expect(swipe.handle(.ended, towardReply: 0, vertical: 0, width: 600) == .cancelled)
    }
    @Test func swipingAwayFromReplyDoesNothing() {
        var swipe = ReplySwipe()
        #expect(swipe.handle(.began, towardReply: -5, vertical: 0, width: 600) == .ignore)
    }
    @Test func rubberBandFollowsTheFingerThenResists() {
        #expect(ReplySwipe.rubberBand(0, width: 600) == 0)
        #expect(ReplySwipe.rubberBand(50, width: 600) <= 50)
        #expect(ReplySwipe.rubberBand(1_000, width: 600) < 1_000)   // resists only past ~600 pt at this width
        #expect(ReplySwipe.rubberBand(1_000, width: 600) > ReplySwipe.rubberBand(500, width: 600))
    }
}
