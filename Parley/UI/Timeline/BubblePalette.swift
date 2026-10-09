import AppKit
import SwiftUI

/// A Telegram-style chat wallpaper (Settings ▸ Wallpaper): a four-colour gradient behind the timeline.
enum Wallpaper: String, CaseIterable, Sendable {
    case none, meadow, ocean, sunset, lavender
    static let doodlesKey = "wallpaperDoodles"
    /// One per appearance, as Telegram keeps a wallpaper for its day and night themes.
    static func key(dark: Bool) -> String { dark ? "wallpaperDark" : "wallpaper" }
    static func current(dark: Bool) -> Wallpaper { UserDefaults.standard.string(forKey: key(dark: dark)).flatMap(Self.init) ?? .none }
    /// Top-left, top-right, bottom-left, bottom-right. Meadow is Telegram's default; the others mix its preset colours.
    var colors: [UInt32] {
        switch self {
        case .none: []
        case .meadow: [0xdbddbb, 0x6ba587, 0xd5d88d, 0x88b884]
        case .ocean: [0xd4dfea, 0x6ab7ea, 0xb3cde1, 0x8bd2cc]
        case .sunset: [0xffd7ae, 0xde8751, 0xffafaf, 0xffb66d]
        case .lavender: [0xd5cef7, 0x9592ed, 0xefd5e0, 0xe8bcea]
        }
    }
}

/// The gradient for the current appearance, dimmed in dark mode so light text and the dark bubbles stay readable.
struct WallpaperView: View {
    var doodles = true
    @AppStorage(Wallpaper.key(dark: false)) private var light = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var dark = Wallpaper.none
    @Environment(\.colorScheme) private var scheme
    private var wallpaper: Wallpaper { scheme == .dark ? dark : light }
    var body: some View {
        if wallpaper != .none {
            MeshGradient(width: 2, height: 2, points: [[0, 0], [1, 0], [0, 1], [1, 1]],
                         colors: wallpaper.colors.map { Color(nsColor: scheme == .dark ? NSColor(rgb: $0).blended(withFraction: 0.7, of: .black)! : NSColor(rgb: $0)) })
                .overlay {
                    if doodles {   // black doodles in soft light, as Telegram blends its pattern; faint light ones in dark mode
                    Image(nsImage: WallpaperPattern.tile).resizable(resizingMode: .tile)
                        .modifier(PatternLook(dark: scheme == .dark))
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false).accessibilityHidden(true)   // decoration: clicks and VoiceOver reach the timeline
        }
    }
}

private struct PatternLook: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        if dark { content.colorInvert().opacity(0.07) } else { content.blendMode(.softLight).opacity(0.5) }
    }
}

/// Parley's own doodle pattern over the gradient: SF Symbols outlines of mixed sizes, scattered at random and turned
/// any way, packed close without touching (dart throwing, as Telegram's doodles sit). Drawn once at launch, then tiled.
@MainActor enum WallpaperPattern {
    static let size: CGFloat = 640
    static let symbols = ["bubble.left", "heart", "star", "camera", "paperplane", "music.note", "cup.and.saucer", "leaf", "moon",
                          "sun.max", "gift", "bell", "pencil", "book", "headphones", "gamecontroller", "airplane", "balloon",
                          "cloud", "bicycle", "umbrella", "fish", "pawprint", "sparkles", "eyeglasses", "hand.thumbsup",
                          "envelope", "lightbulb", "globe.americas", "puzzlepiece", "birthday.cake", "tortoise", "hare",
                          "camera.macro", "theatermasks", "crown", "flame", "drop", "snowflake", "bolt", "car", "house",
                          "carrot", "fork.knife", "basketball", "soccerball", "tennisball", "guitars", "paintbrush", "scissors",
                          "key", "flag", "map", "tent", "mountain.2", "beach.umbrella", "sailboat", "bird", "ladybug", "ant",
                          "atom", "dice", "trophy", "graduationcap", "bus", "tram", "binoculars", "cat", "dog", "teddybear",
                          "popcorn", "wineglass", "mug", "cloud.rain", "rainbow", "tree", "camera.aperture", "film", "magnifyingglass"]
    struct Placement: Equatable { var symbol: String; var center: CGPoint; var angle: CGFloat; var points: CGFloat }
    /// Seeded, so the pattern is the same on every launch and every Mac. Distances wrap around the tile's edges, so a
    /// doodle near one edge leaves room for those across the seam, and the tiling shows no seam.
    static let placements: [Placement] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        let available = symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
        var placed: [Placement] = [], pool: [String] = []
        for _ in 0..<20000 {
            let points = 16 + 22 * next() * next()   // mostly small, a few big
            let center = CGPoint(x: next() * size, y: next() * size)
            let fits = placed.allSatisfy { q in
                var dx = abs(center.x - q.center.x), dy = abs(center.y - q.center.y)
                dx = min(dx, size - dx); dy = min(dy, size - dy)
                return (dx * dx + dy * dy).squareRoot() >= (points + q.points) * 0.62 + 2
            }
            guard fits else { continue }
            if pool.isEmpty { pool = available }
            let symbol = pool.remove(at: Int(next() * CGFloat(pool.count)) % pool.count)
            placed.append(Placement(symbol: symbol, center: center, angle: (next() - 0.5) * .pi, points: points))
        }
        return placed
    }()
    static let tile: NSImage = {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            for p in placements {   // one near an edge is drawn again across it, where the next tile starts
                for dx in [-size, 0, size] where abs(p.center.x + dx - size / 2) < size / 2 + p.points {
                    for dy in [-size, 0, size] where abs(p.center.y + dy - size / 2) < size / 2 + p.points {
                        draw(p, at: CGPoint(x: p.center.x + dx, y: p.center.y + dy))
                    }
                }
            }
            return true
        }
    }()
    private static func draw(_ p: Placement, at center: CGPoint) {
        let config = NSImage.SymbolConfiguration(pointSize: p.points, weight: .regular).applying(.init(paletteColors: [.black]))
        guard let symbol = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        NSGraphicsContext.saveGraphicsState()
        let turn = NSAffineTransform()
        turn.translateX(by: center.x, yBy: center.y); turn.rotate(byRadians: p.angle); turn.concat()
        symbol.draw(in: NSRect(x: -symbol.size.width / 2, y: -symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Bubble colours: mine in the accent colour or the one chosen in Settings, with white or black text, whichever reads
/// on it; others' grey, or white (dark grey in dark mode) on a wallpaper, as Telegram draws them.
enum BubblePalette {
    /// "#RRGGBB" per appearance, as Telegram keeps a colour for its day and night themes; unset: the accent colour.
    static func colorKey(dark: Bool) -> String { dark ? "bubbleColorDark" : "bubbleColor" }
    static func own(dark: Bool) -> NSColor {
        UserDefaults.standard.string(forKey: colorKey(dark: dark)).flatMap(NSColor.init(hex:)) ?? .controlAccentColor
    }
    // Dynamic: each resolves for the appearance it is drawn in, so switching light and dark swaps the settings too.
    static let own = NSColor(name: nil) { resolved(own(dark: $0.isDark), in: $0) }
    /// Text and icons on my bubble.
    static let ownInk = NSColor(name: nil) { ink(on: resolved(own(dark: $0.isDark), in: $0)) }
    /// A chip or card on my bubble: a shade darker under white text, lighter under black.
    static let ownWell = NSColor(name: nil) {
        ink(on: resolved(own(dark: $0.isDark), in: $0)) == .white ? .black.withAlphaComponent(0.22) : .white.withAlphaComponent(0.45)
    }
    static let incoming = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none ? resolved(.unemphasizedSelectedContentBackgroundColor, in: $0)
            : $0.isDark ? NSColor(rgb: 0x3d414d) : .white
    }
    /// Date headers and service lines: white on a tinted pill over a wallpaper, as Telegram draws them; else plain grey.
    static let serviceText = NSColor(name: nil) { Wallpaper.current(dark: $0.isDark) == .none ? resolved(.secondaryLabelColor, in: $0) : .white }
    static let servicePill = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none ? .clear : .black.withAlphaComponent($0.isDark ? 0.5 : 0.25)
    }
    /// The time beside large emoji: the service pill over a wallpaper, a faint one without.
    static let timePill = NSColor(name: nil) {
        Wallpaper.current(dark: $0.isDark) == .none ? resolved(.labelColor.withAlphaComponent(0.06), in: $0) : .black.withAlphaComponent($0.isDark ? 0.5 : 0.25)
    }
    private static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) ?? color }
        return result
    }
    /// Black once the fill's relative luminance passes 0.45: white stays on Apple's blue, green and orange, as Messages
    /// draws them, and black goes on yellow and pale fills.
    // ponytail: a luminance cut, not a contrast ratio; WCAG's ratio prefers black even on Apple's blue.
    static func ink(on fill: NSColor) -> NSColor {
        guard let c = fill.usingColorSpace(.sRGB) else { return .white }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        return luminance > 0.45 ? .black : .white
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
    convenience init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(rgb: rgb)
    }
    var hex: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
