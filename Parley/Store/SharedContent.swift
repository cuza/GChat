import Foundation

/// What a conversation's loaded messages share, for the info panel: newest first, each attachment or link once.
struct SharedContent: Equatable {
    struct Item: Hashable, Identifiable {
        var attachment: Attachment   // links are `.link` attachments: a preview's, or one made from the URL
        var date: Date
        var sender: String
        var messageID: MessageID? = nil   // the message that shared it: server results page on from it
        var id: String { attachment.url?.absoluteString ?? "\(attachment.name)|\(attachment.contentType)" }
    }
    private(set) var media: [Item] = [], files: [Item] = [], links: [Item] = []

    init(_ messages: [Message]) {
        var seen: Set<String> = []
        for message in messages.filter({ $0.delivery == .sent && !$0.isSystem }).sorted(by: { $0.createdAt > $1.createdAt }) {
            for attachment in message.attachments + Self.links(in: message) {
                let item = Item(attachment: attachment, date: message.createdAt, sender: message.sender.name, messageID: message.id)
                guard seen.insert(item.id).inserted else { continue }
                switch attachment.kind {
                case .image, .video: media.append(item)
                case .file, .voice: files.append(item)
                case .link: links.append(item)
                case .call, .card: break   // calls and cards are not shared content
                }
            }
        }
    }
    /// Web links in the text: annotated ones, then any the server left bare.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static func links(in message: Message) -> [Attachment] {
        let annotated = message.formatting.compactMap { range -> URL? in if case .link(let url) = range.style { url } else { nil } }
        let text = message.text
        let bare = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return (annotated + bare).filter { ["http", "https"].contains($0.scheme?.lowercased()) }
            .map { Attachment(name: $0.absoluteString, kind: .link, url: $0) }
    }
}

extension ChatStore {
    /// ⌘I or the title: opens the info panel in place of a thread, or closes it.
    func toggleInfo() {
        info.toggle()
        if info { threadID = nil }
    }
    /// Everyone in the conversation, me included: the full list once `loadMembers` has it, else the members it came with.
    func roster(_ conversation: Conversation) -> [Person] {
        members[conversation.id] ?? conversation.members
    }
}
