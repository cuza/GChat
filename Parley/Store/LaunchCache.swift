import Foundation

struct LaunchSnapshot: Codable, Sendable {
    var accountID: String?   // whose cache this is; another account's is discarded when that account connects
    var conversations: [Conversation] = []
    var messages: [Message] = []
    var selectedID: ConversationID?
    var drafts: [String: String] = [:]
    var draftFormatting: [String: [TextStyleRange]] = [:]
    var draftEdits: [String: Date] = [:]   // drafts changed on this Mac since last saved to Google, and when
    var serverDrafts: [String: ServerDraft] = [:]   // per draft key, Google's copy as last saved or heard of
    var homeThreads: [HomeThread] = []
}
extension LaunchSnapshot {
    /// Caches written before draft formatting existed lack that key. Ones written before server drafts count every draft
    /// as an old local edit, never saved to Google: pushed unless Google has a draft there too.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let drafts = try c.decode([String: String].self, forKey: .drafts)
        // A model change loses cached history, which the server has, never drafts, which only this file has.
        self.init(accountID: try c.decodeIfPresent(String.self, forKey: .accountID),
                  conversations: (try? c.decode([Conversation].self, forKey: .conversations)) ?? [],
                  messages: (try? c.decode([Message].self, forKey: .messages)) ?? [],
                  selectedID: try c.decodeIfPresent(ConversationID.self, forKey: .selectedID), drafts: drafts,
                  draftFormatting: try c.decodeIfPresent([String: [TextStyleRange]].self, forKey: .draftFormatting) ?? [:],
                  draftEdits: try c.decodeIfPresent([String: Date].self, forKey: .draftEdits) ?? drafts.filter { !$0.value.isEmpty }.mapValues { _ in .distantPast },
                  serverDrafts: try c.decodeIfPresent([String: ServerDraft].self, forKey: .serverDrafts) ?? [:],
                  homeThreads: (try? c.decodeIfPresent([HomeThread].self, forKey: .homeThreads)) ?? [])
    }
}
struct LaunchCache: Sendable {
    let url: URL
    #if DEBUG   // its own file, as with the Keychain: a debug build signed into another account doesn't swap the installed app's
    static let dynamite = LaunchCache(url: URL.applicationSupportDirectory.appending(path: "Parley/cache-debug.json"))
    #else
    static let dynamite = LaunchCache(url: URL.applicationSupportDirectory.appending(path: "Parley/cache.json"))
    #endif
    func load() -> LaunchSnapshot {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(LaunchSnapshot.self, from: data) else { return LaunchSnapshot() }
        return value
    }
    func save(_ snapshot: LaunchSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
