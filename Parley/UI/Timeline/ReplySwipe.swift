import AppKit

/// Two-finger swipe toward the reply arrow, like Telegram for macOS: starts only on a purely horizontal first event,
/// follows the fingers with a rubber band, arms a quote reply at 100 pt and a thread reply at 190 pt (one haptic each time it crosses either), and on
/// release does whichever is armed.
struct ReplySwipe {
    enum Stage: Equatable { case quote, thread }
    static let threshold: CGFloat = 100
    /// Reached by the rubber band with about 210 pt of finger travel even on a 300 pt row.
    static let threadThreshold: CGFloat = 190
    enum Outcome: Equatable {
        case ignore, began, cancelled
        case committed(Stage)
        /// `offset` is the row's horizontal shift (negative: toward the arrow); `crossed` fires the haptic.
        case moved(offset: CGFloat, stage: Stage?, crossed: Bool)
    }
    /// False where there is no thread to open (inside a thread): only quote applies.
    var allowsThread = true
    private var active = false
    private var travel: CGFloat = 0
    private var stage: Stage?

    /// `towardReply` is the horizontal scroll delta already oriented so positive moves toward the reply arrow
    /// (the caller accounts for natural scrolling).
    mutating func handle(_ phase: NSEvent.Phase, towardReply: CGFloat, vertical: CGFloat, width: CGFloat) -> Outcome {
        switch phase {
        case .began:
            guard vertical == 0, towardReply > 0 else { active = false; return .ignore }
            active = true; travel = 0; stage = nil
            return .began
        case .changed:
            guard active else { return .ignore }
            travel = max(0, travel + towardReply)
            let shift = Self.rubberBand(travel, width: width)
            let now: Stage? = shift >= Self.threadThreshold && allowsThread ? .thread : shift >= Self.threshold ? .quote : nil
            defer { stage = now }
            return .moved(offset: -shift, stage: now, crossed: now != stage)
        case .ended, .cancelled:
            guard active else { return .ignore }
            active = false
            if let stage, phase == .ended { return .committed(stage) }
            return .cancelled
        default:
            return active ? .moved(offset: -Self.rubberBand(travel, width: width), stage: stage, crossed: false) : .ignore
        }
    }
    /// The scroll-view rubber band, x·d / (x + d): follows the finger at first, then slows toward d, six row widths.
    static func rubberBand(_ travel: CGFloat, width: CGFloat) -> CGFloat {
        guard travel > 0 else { return 0 }
        let limit = width * 6
        return travel * limit / (travel + limit)
    }
}
