import SwiftUI

struct Emoji: Hashable, Sendable {
    let character: String
    let name: String   // lowercased: the Unicode name, or "flag " and the region's English name
}

/// Every emoji the system knows as a single scalar, plus the regions' flags, grouped like the system picker.
/// Read from the Unicode properties at run time, so it grows with the OS and needs no bundled list.
enum EmojiCatalog {
    struct Category: Sendable {
        let name: String
        let symbol: String   // its tab's SF Symbol
        let emoji: [Emoji]
    }
    static let categories: [Category] = build()
    private static let index = Dictionary(categories.flatMap(\.emoji).map { ($0.character, $0) }, uniquingKeysWith: { first, _ in first })
    static func emoji(_ character: String) -> Emoji { index[character] ?? Emoji(character: character, name: "") }

    private static let names: [(name: String, symbol: String)] = [
        ("Smileys & People", "face.smiling"), ("Animals & Nature", "leaf"), ("Food & Drink", "fork.knife"), ("Activity", "basketball"),
        ("Travel & Places", "car"), ("Objects", "lightbulb"), ("Symbols", "heart"), ("Flags", "flag"),
    ]
    /// Unicode ranges and the category they go to, in display order; the first listed range claims a scalar. Anything
    /// unlisted is a symbol.
    // ponytail: block ranges only approximate the system picker's grouping (a few emoji land in a neighbouring
    // category, and order is code point order); a bundled CLDR ordering would fix both if it ever matters.
    private static let ranges: [(ClosedRange<UInt32>, Int)] = [
        // Smileys & People
        (0x1F600...0x1F64F, 0), (0x1F910...0x1F92F, 0), (0x1F970...0x1F97A, 0), (0x1F9D0...0x1F9DF, 0), (0x1FAE0...0x1FAEF, 0),
        (0x263A...0x263A, 0), (0x2639...0x2639, 0), (0x1F440...0x1F450, 0), (0x1FAF0...0x1FAF8, 0), (0x261D...0x261D, 0),
        (0x270A...0x270D, 0), (0x1F590...0x1F596, 0), (0x1F466...0x1F487, 0), (0x1F48B...0x1F48B, 0), (0x1F48F...0x1F48F, 0),
        (0x1F491...0x1F491, 0), (0x1F4A9...0x1F4AA, 0), (0x1F930...0x1F93A, 0), (0x1F977...0x1F977, 0), (0x1F9B5...0x1F9B9, 0),
        (0x1F9BB...0x1F9BB, 0), (0x1F9CD...0x1F9CF, 0), (0x1F9E0...0x1F9E0, 0), (0x1FAC3...0x1FAC5, 0), (0x1F574...0x1F576, 0),
        (0x1F579...0x1F57A, 0), (0x1F6B4...0x1F6B6, 0), (0x1F6C0...0x1F6C0, 0), (0x1F6CC...0x1F6CC, 0), (0x1F385...0x1F385, 0),
        (0x1F3C2...0x1F3C4, 0), (0x1F3C7...0x1F3C7, 0), (0x1F3CA...0x1F3CC, 0), (0x26F9...0x26F9, 0),
        (0x1F451...0x1F462, 0), (0x1F97B...0x1F97F, 0), (0x1F9E2...0x1F9E6, 0), (0x1FA70...0x1FA73, 0),
        // Travel & Places, before the sky and sports ranges below take its scalars
        (0x1F301...0x1F301, 4), (0x1F303...0x1F307, 4), (0x1F309...0x1F309, 4), (0x1F30B...0x1F30B, 4), (0x1F30D...0x1F310, 4),
        (0x1F3A0...0x1F3A2, 4), (0x1F3CD...0x1F3CE, 4),
        // Animals & Nature
        (0x1F400...0x1F43F, 1), (0x1F980...0x1F9AE, 1), (0x1FAB0...0x1FABF, 1), (0x1FACE...0x1FACF, 1), (0x1F577...0x1F578, 1),
        (0x1F54A...0x1F54A, 1), (0x1F330...0x1F344, 1), (0x1F490...0x1F490, 1), (0x1F940...0x1F940, 1), (0x1F300...0x1F32C, 1),
        (0x2600...0x2604, 1), (0x2614...0x2614, 1), (0x26A1...0x26A1, 1), (0x26C4...0x26C8, 1), (0x2744...0x2744, 1),
        (0x2B50...0x2B50, 1), (0x1FA90...0x1FA90, 1), (0x1FAA8...0x1FAA8, 1), (0x1F525...0x1F525, 1),
        // Food & Drink
        (0x1F345...0x1F37F, 2), (0x1F32D...0x1F32F, 2), (0x1F950...0x1F96F, 2), (0x1F9C0...0x1F9CB, 2), (0x1FAD0...0x1FADF, 2),
        (0x1F942...0x1F944, 2), (0x2615...0x2615, 2), (0x1F382...0x1F382, 2),
        // Activity
        (0x1F380...0x1F393, 3), (0x1F396...0x1F397, 3), (0x1F39E...0x1F39F, 3), (0x1F3A3...0x1F3CF, 3), (0x1F3F8...0x1F3F9, 3),
        (0x1F93C...0x1F93F, 3), (0x1F945...0x1F94F, 3), (0x1FA80...0x1FA8F, 3), (0x26BD...0x26BE, 3), (0x26F3...0x26F3, 3),
        (0x26F8...0x26F8, 3), (0x1F9E9...0x1F9E9, 3), (0x1F9F8...0x1F9F8, 3), (0x265F...0x265F, 3), (0x1F0CF...0x1F0CF, 3),
        (0x1F004...0x1F004, 3),
        // Travel & Places
        (0x1F680...0x1F6FF, 4), (0x1F3D4...0x1F3DF, 4), (0x1F3E0...0x1F3F0, 4), (0x1F5FA...0x1F5FF, 4), (0x1F488...0x1F488, 4),
        (0x1F492...0x1F492, 4), (0x1F550...0x1F567, 4), (0x231A...0x231B, 4), (0x23F0...0x23F3, 4), (0x2693...0x2693, 4),
        (0x26EA...0x26EA, 4), (0x26F0...0x26F5, 4), (0x26F7...0x26F7, 4), (0x26FA...0x26FA, 4), (0x26FD...0x26FD, 4),
        (0x2708...0x2708, 4),
        // Objects
        (0x1F4A1...0x1F4A1, 5), (0x1F4A3...0x1F4A3, 5), (0x1F48C...0x1F48E, 5), (0x1F4B0...0x1F4FF, 5), (0x1F507...0x1F517, 5),
        (0x1F526...0x1F52E, 5), (0x1F56F...0x1F5F3, 5), (0x1F399...0x1F39B, 5), (0x1F3F7...0x1F3F7, 5), (0x1F3FA...0x1F3FA, 5),
        (0x1F9E7...0x1F9FF, 5), (0x1FA74...0x1FA7F, 5), (0x1FA91...0x1FAAF, 5), (0x1F9AF...0x1F9AF, 5), (0x1F9BA...0x1F9BA, 5),
        (0x1F9BC...0x1F9BF, 5), (0x2328...0x2328, 5), (0x260E...0x260E, 5), (0x2692...0x2697, 5), (0x2699...0x269B, 5),
        (0x26B0...0x26B1, 5), (0x26CF...0x26CF, 5), (0x26D1...0x26D1, 5), (0x26D3...0x26D3, 5), (0x2702...0x2702, 5),
        (0x2709...0x2709, 5), (0x270F...0x270F, 5), (0x2712...0x2712, 5),
    ]
    /// Skin-tone swatches, lone regional indicator letters and hair components only make sense inside sequences.
    private static let parts: [ClosedRange<UInt32>] = [0x1F3FB...0x1F3FF, 0x1F1E6...0x1F1FF, 0x1F9B0...0x1F9B3]

    private static func build() -> [Category] {
        var claimed = Set<UInt32>()
        var groups = Array(repeating: [Emoji](), count: names.count)
        func add(_ value: UInt32, to group: Int) {
            guard !claimed.contains(value), let scalar = Unicode.Scalar(value) else { return }
            let properties = scalar.properties
            // Above Latin-1, so digits, #, * (keycap bases) and ©/® stay text.
            guard properties.isEmoji, value > 0xFF, !parts.contains(where: { $0.contains(value) }) else { return }
            claimed.insert(value)
            let character = properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
            groups[group].append(Emoji(character: character, name: (properties.name ?? "").lowercased()))
        }
        for (range, group) in ranges { for value in range { add(value, to: group) } }
        for value in UInt32(0x100)...0x1FAFF { add(value, to: 6) }
        let english = Locale(identifier: "en_US")
        groups[7] = Locale.Region.isoRegions.compactMap { region -> Emoji? in
            let code = region.identifier
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isUppercase }),
                  let name = english.localizedString(forRegionCode: code) else { return nil }
            let flag = String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
            return Emoji(character: flag, name: "flag " + name.lowercased())
        }.sorted { $0.name < $1.name }
        return zip(names, groups).map { Category(name: $0.name, symbol: $0.symbol, emoji: $1) }
    }

    /// Everyday words the Unicode names don't contain.
    private static let keywords: [String: [String]] = [
        "lol": ["😂", "🤣"], "haha": ["😂", "😆"], "laugh": ["😂", "🤣", "😆"], "like": ["👍"], "+1": ["👍"], "yes": ["👍", "✅"],
        "ok": ["👌", "👍"], "no": ["👎", "❌"], "love": ["❤️", "😍", "🥰"], "thanks": ["🙏"], "please": ["🙏"], "party": ["🎉", "🥳"],
        "congrats": ["🎉", "👏"], "sad": ["😢", "😭"], "wow": ["😮", "🤯"], "done": ["✅"], "happy": ["😀", "😊"], "cool": ["😎"],
    ]
    /// Emoji whose name has a word starting with each word of `query`; everyday keywords first.
    static func search(_ query: String) -> [Emoji] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        let words = query.split(separator: " ")
        guard !words.isEmpty else { return [] }
        let byKeyword = keywords.filter { $0.key.hasPrefix(query) }.sorted { $0.key < $1.key }.flatMap(\.value).map(emoji)
        let byName = categories.lazy.flatMap(\.emoji).filter { emoji in
            let nameWords = emoji.name.split { !$0.isLetter && !$0.isNumber }
            return words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
        }
        var seen = Set<String>()
        return (byKeyword + byName).filter { seen.insert($0.character).inserted }
    }
}

/// How often I react with each emoji, kept in the user defaults: the quick reactions and the picker's first row.
struct EmojiUsage {
    static let defaults = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    private static let key = "emojiUsage"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ emoji: String) {
        var counts = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        counts[emoji, default: 0] += 1
        defaults.set(counts, forKey: Self.key)
    }
    /// The `count` most used, most first (a default wins a tie), filled up from the defaults.
    func top(_ count: Int) -> [String] {
        let counts = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
        let rank = { (emoji: String) in Self.defaults.firstIndex(of: emoji) ?? Self.defaults.count }
        let used = counts.keys.sorted { (counts[$1]!, rank($0), $0) < (counts[$0]!, rank($1), $1) }
        return Array((used + Self.defaults.filter { counts[$0] == nil }).prefix(count))
    }
}

/// Keyboard moves through a grid made of sections, each starting a new row.
enum EmojiGrid {
    enum Direction { case up, down, left, right }
    static func move(_ index: Int, _ direction: Direction, sizes: [Int], columns: Int) -> Int {
        let total = sizes.reduce(0, +)
        guard total > 0 else { return 0 }
        var section = 0, offset = 0
        while section < sizes.count - 1 && index >= offset + sizes[section] { offset += sizes[section]; section += 1 }
        let position = index - offset, column = position % columns
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(total - 1, index + 1)
        case .down:
            if (position / columns + 1) * columns < sizes[section] { return offset + min(position + columns, sizes[section] - 1) }
            guard section + 1 < sizes.count else { return index }
            return offset + sizes[section] + min(column, sizes[section + 1] - 1)
        case .up:
            if position >= columns { return index - columns }
            guard section > 0 else { return index }
            let size = sizes[section - 1], lastRow = (size - 1) / columns * columns
            return offset - size + min(lastRow + column, size - 1)
        }
    }
}

/// The full reaction picker: search, the most used, the organisation's custom emoji, then every category, with tabs
/// to jump between them. Arrows move, Return picks, Esc closes.
struct EmojiPicker: View {
    static let columns = 9
    let frequent: [String]
    let pick: (String) -> Void
    let close: () -> Void
    /// The organisation's custom emoji, asked for when the picker opens; nil offers none.
    var custom: (() async -> [CustomEmoji])? = nil
    var pickCustom: (CustomEmoji) -> Void = { _ in }
    var loadImage: (Attachment, Bool) async throws -> Data = { _, _ in throw CancellationError() }
    @State private var customEmoji: [CustomEmoji] = []
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searching: Bool

    /// Custom emoji sit in the grid as their ":shortcode:", which no Unicode emoji can be.
    private var sections: [(title: String, emoji: [Emoji])] {
        func cells(_ emoji: [CustomEmoji]) -> [Emoji] { emoji.map { Emoji(character: $0.text, name: $0.shortcode) } }
        let search = query.trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ":")))
        guard search.isEmpty else {
            return [("Search Results", cells(MentionQuery.filter(customEmoji, by: search, limit: .max)) + EmojiCatalog.search(search))]
        }
        return [("Frequently Used", frequent.map(EmojiCatalog.emoji)), ("Custom", cells(customEmoji))] + EmojiCatalog.categories.map { ($0.name, $0.emoji) }
    }
    private func choose(_ emoji: Emoji) {
        if let custom = customEmoji.first(where: { $0.text == emoji.character }) { pickCustom(custom) } else { pick(emoji.character) }
    }
    var body: some View {
        let sections = sections.filter { !$0.emoji.isEmpty }
        let flat = sections.flatMap(\.emoji)
        let starts = sections.indices.map { index in sections[..<index].reduce(0) { $0 + $1.emoji.count } }
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                TextField("Search Emoji", text: $query)
                    .textFieldStyle(.roundedBorder).focused($searching).padding(10)
                    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                        let direction: EmojiGrid.Direction = switch press.key {
                        case .upArrow: .up
                        case .downArrow: .down
                        case .leftArrow: .left
                        default: .right
                        }
                        if (direction == .left || direction == .right) && !query.isEmpty { return .ignored }   // the caret's keys
                        selection = EmojiGrid.move(selection, direction, sizes: sections.map(\.emoji.count), columns: Self.columns)
                        proxy.scrollTo(selection)
                        return .handled
                    }
                    .onSubmit { if flat.indices.contains(selection) { choose(flat[selection]) } }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 3), count: Self.columns), spacing: 3,
                              pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                            Section {
                                ForEach(Array(section.emoji.enumerated()), id: \.offset) { offset, emoji in
                                    cell(emoji, index: starts[index] + offset)
                                }
                            } header: {
                                Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).background(.background)
                                    .id("section \(index)")
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 6)
                }
                .overlay { if flat.isEmpty { Text("No Emoji Found").foregroundStyle(.secondary) } }
                if query.isEmpty {
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                            let symbol = section.title == "Frequently Used" ? "clock" : section.title == "Custom" ? "building.2"
                                : EmojiCatalog.categories.first { $0.name == section.title }?.symbol ?? "circle"
                            let current = (starts[index]..<starts[index] + section.emoji.count).contains(selection)
                            Button { selection = starts[index]; proxy.scrollTo("section \(index)", anchor: .top) } label: {
                                Image(systemName: symbol).frame(maxWidth: .infinity, minHeight: 26)
                                    .foregroundStyle(current ? Color.accentColor : .secondary).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help(section.title).accessibilityLabel(section.title)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
        .frame(width: 10 * 2 + CGFloat(Self.columns) * 35, height: 380)
        .onAppear { searching = true }
        .task { if let custom { customEmoji = await custom() } }
        .onChange(of: query) { selection = 0 }
        .onExitCommand(perform: close)
    }
    private func cell(_ emoji: Emoji, index: Int) -> some View {
        let custom = customEmoji.first { $0.text == emoji.character }
        return Group {
            if let custom { CustomEmojiImage(emoji: custom, size: 26, load: loadImage) } else { Text(emoji.character).font(.system(size: 24)) }
        }
            .frame(width: 32, height: 32)
            .background(index == selection ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { choose(emoji) }
            .onHover { if $0 { selection = index } }
            .help(custom?.text ?? emoji.name.capitalized)
            .accessibilityLabel(emoji.name.isEmpty ? emoji.character : emoji.name)
            .accessibilityAddTraits(.isButton)
            .id(index)
    }
}

/// A custom emoji's picture at `size`, from `ImageCache` or fetched with `load`; a faint square until it arrives.
struct CustomEmojiImage: View {
    let emoji: CustomEmoji
    var size: CGFloat = 24
    let load: (Attachment, Bool) async throws -> Data
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { RoundedRectangle(cornerRadius: 4).fill(.quaternary) }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(emoji.text)
        .task(id: emoji.id) {
            guard let picture = emoji.image else { return }
            image = ImageCache.cached(picture)
            if image == nil { image = try? await ImageCache.load(picture, load) }
        }
    }
}
