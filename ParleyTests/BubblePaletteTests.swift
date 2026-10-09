import SwiftUI
import AppKit
import Testing
@testable import Parley

@MainActor struct BubblePaletteTests {
    @Test func textOnMyBubbleIsWhiteOrBlackWhicheverReads() {
        #expect(BubblePalette.ink(on: NSColor(rgb: 0x007AFF)) == .white)   // Apple blue
        #expect(BubblePalette.ink(on: NSColor(rgb: 0x34C759)) == .white)   // green
        #expect(BubblePalette.ink(on: NSColor(rgb: 0xFFCC00)) == .black)   // yellow
        #expect(BubblePalette.ink(on: NSColor(rgb: 0xE1FFC7)) == .black)   // Telegram's pale green
    }
    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var result = NSColor.clear
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB)! }
        return result
    }
    private func keeping(_ keys: [String], _ body: () -> Void) {
        let defaults = UserDefaults.standard, saved = keys.map { defaults.string(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        body()
    }
    @Test func eachAppearanceKeepsItsOwnBubbleColorAndText() {
        keeping([BubblePalette.colorKey(dark: false), BubblePalette.colorKey(dark: true)]) {
            UserDefaults.standard.set(NSColor(rgb: 0xFFCC00).hex, forKey: BubblePalette.colorKey(dark: false))
            UserDefaults.standard.set("#1F3A5F", forKey: BubblePalette.colorKey(dark: true))
            #expect(UserDefaults.standard.string(forKey: BubblePalette.colorKey(dark: false)) == "#FFCC00")
            #expect(resolved(BubblePalette.own, .aqua) == NSColor(rgb: 0xFFCC00).usingColorSpace(.sRGB)!)
            #expect(resolved(BubblePalette.ownInk, .aqua) == NSColor.black.usingColorSpace(.sRGB)!)
            #expect(resolved(BubblePalette.own, .darkAqua) == NSColor(rgb: 0x1F3A5F).usingColorSpace(.sRGB)!)
            #expect(resolved(BubblePalette.ownInk, .darkAqua) == NSColor.white.usingColorSpace(.sRGB)!)
            UserDefaults.standard.removeObject(forKey: BubblePalette.colorKey(dark: false))
            #expect(BubblePalette.own(dark: false) == .controlAccentColor)
        }
    }
    @Test func othersBubblesTurnWhiteOrDarkOnlyWhereThatAppearanceHasAWallpaper() {
        keeping([Wallpaper.key(dark: false), Wallpaper.key(dark: true)]) {
            UserDefaults.standard.set(Wallpaper.meadow.rawValue, forKey: Wallpaper.key(dark: false))
            UserDefaults.standard.set(Wallpaper.none.rawValue, forKey: Wallpaper.key(dark: true))
            #expect(resolved(BubblePalette.incoming, .aqua) == NSColor.white.usingColorSpace(.sRGB)!)
            #expect(resolved(BubblePalette.serviceText, .aqua) == NSColor.white.usingColorSpace(.sRGB)!)
            #expect(resolved(BubblePalette.incoming, .darkAqua) == resolved(.unemphasizedSelectedContentBackgroundColor, .darkAqua))
            #expect(resolved(BubblePalette.servicePill, .darkAqua).alphaComponent == 0)
            UserDefaults.standard.set(Wallpaper.ocean.rawValue, forKey: Wallpaper.key(dark: true))
            #expect(resolved(BubblePalette.incoming, .darkAqua).brightnessComponent < 0.35)
        }
    }
}

@MainActor struct WallpaperPatternTests {
    @Test func theDoodleTileIsTheSameEveryTimeAndHasDoodles() throws {
        let a = WallpaperPattern.placements, b = WallpaperPattern.placements
        #expect(a == b && a.count > 150)   // dense, like Telegram's
        // Scattered, not on a grid, yet never touching, even across the tile's wrapped edges.
        let size = WallpaperPattern.size
        for (i, p) in a.enumerated() {
            for q in a[(i + 1)...] {
                var dx = abs(p.center.x - q.center.x), dy = abs(p.center.y - q.center.y)
                dx = min(dx, size - dx); dy = min(dy, size - dy)
                #expect((dx * dx + dy * dy).squareRoot() >= (p.points + q.points) * 0.5)
            }
        }
        #expect(Set(a.map { Int($0.points) }).count > 8 && Set(a.map(\.symbol)).count > 30)
        let tile = try #require(WallpaperPattern.tile.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: tile)
        let inked = (0..<bitmap.pixelsWide).lazy.filter { x in (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 } }
        #expect(inked.count > bitmap.pixelsWide / 2)   // doodles across most of the tile's width
    }
}

@MainActor struct BubbleColorPickerTests {
    /// The color panel works in Display P3; read back from the stored sRGB hex it never matches exactly. Treating that
    /// as a change re-saved the color, which reset the panel, which reported a change again: the picker never settled.
    @Test func aPickedColorThatRoundsToTheStoredOneIsNoChange() throws {
        let stored = "#3478F6"
        let p3 = try #require(NSColor(hex: stored)?.usingColorSpace(.displayP3))
        #expect(BubbleColorPicker.change(from: stored, to: Color(nsColor: p3)) == nil)
        #expect(BubbleColorPicker.change(from: stored, to: Color(nsColor: NSColor(rgb: 0xFF0000))) == "#FF0000")
        #expect(BubbleColorPicker.change(from: "", to: Color(nsColor: NSColor(rgb: 0xFF0000))) == "#FF0000")
    }
}
