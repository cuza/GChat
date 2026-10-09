import SwiftUI

/// What the ⌘K / New Chat palette lists for a query: matching conversations, then people without a listed DM
/// (and not already picked for a group DM), then directory spaces not in the sidebar.
struct PaletteResults {
    enum Item: Hashable, Identifiable {
        case conversation(Conversation), person(Person), space(SpaceListing)
        var id: String {
            switch self {
            case .conversation(let room): "c:" + room.id
            case .person(let person): "p:" + person.id
            case .space(let space): "s:" + space.id
            }
        }
    }
    let conversations: [Conversation]
    let people: [Person]
    let spaces: [SpaceListing]
    init(query: String, conversations: [Conversation], people: [Person], spaces: [SpaceListing], picked: [Person]) {
        let query = query.trimmingCharacters(in: .whitespaces)
        func matches(_ text: String?) -> Bool { query.isEmpty || text?.localizedCaseInsensitiveContains(query) == true }
        self.conversations = conversations.filter { matches($0.name) }
        let listedDMs = Set(self.conversations.filter { $0.kind == .direct }.flatMap(\.members).map(\.id))
        let pickedIDs = Set(picked.map(\.id))
        self.people = people.filter { !listedDMs.contains($0.id) && !pickedIDs.contains($0.id) && (matches($0.name) || matches($0.email)) }
        let inSidebar = Set(conversations.map(\.id))
        self.spaces = spaces.filter { !$0.joined && !inSidebar.contains($0.id) && matches($0.name) }
    }
    var items: [Item] { conversations.map(Item.conversation) + people.map(Item.person) + spaces.map(Item.space) }
}

/// ⌘K jumps to a conversation, or finds someone to message or a space to join. `newChat` (⌘N, the sidebar's
/// compose button) lists known people and the space directory before anything is typed.
struct ConversationPalette: View {
    @Bindable var store: ChatStore
    var newChat = false
    var then: ((ConversationID) -> Void)? = nil   // after opening the pick: Forward… leaves the message there
    @State private var query = ""
    @State private var selected: String?
    @State private var people: [Person] = []
    @State private var spaces: [SpaceListing] = []
    @State private var picked: [Person] = []   // a group DM in the making
    @State private var searching = false
    @State private var working = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    private var results: PaletteResults {
        PaletteResults(query: query, conversations: newChat && query.isEmpty ? [] : store.conversations, people: people, spaces: spaces, picked: picked)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(picked) { person in
                    HStack(spacing: 3) {
                        Text(person.name).lineLimit(1)
                        Button { picked.removeAll { $0.id == person.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(person.name)")
                    }.font(.callout).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                }
                TextField(then != nil ? "Forward to a conversation or person" : newChat || !picked.isEmpty ? "Name or email, or a space to join" : "Jump to a conversation, person or space", text: $query)
                    .textFieldStyle(.plain).font(.title3).onSubmit { choose() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                if searching || working { ProgressView().controlSize(.small) }
            }.padding(18)
            Divider()
            List(selection: $selected) {
                let results = results
                if !results.conversations.isEmpty {
                    Section("Conversations") {
                        ForEach(results.conversations) { room in
                            row(.conversation(room)) {
                                Avatar(name: room.name, space: room.kind == .space, size: 22, url: room.avatarURL, emoji: room.emoji)
                                Text(room.name).lineLimit(1)
                            }
                        }
                    }
                }
                if !results.people.isEmpty {
                    Section("People") {
                        ForEach(results.people) { person in
                            row(.person(person)) {
                                Avatar(name: person.name, size: 22, url: person.avatarURL)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name).lineLimit(1)
                                    if let email = person.email, email != person.name { Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                                Button { pick(person) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                                    .help("Add to a group message (⌘Return)").accessibilityLabel("Add \(person.name) to a group message")
                            }
                        }
                    }
                }
                if !results.spaces.isEmpty {
                    Section(newChat ? "Browse spaces" : "Spaces") {
                        ForEach(results.spaces) { space in
                            row(.space(space)) {
                                Avatar(name: space.name, space: true, size: 22, url: space.avatarURL, emoji: space.emoji)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(space.name).lineLimit(1)
                                    if let count = space.memberCount { Text("\(count) members").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                Text("Join").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }.frame(height: 320)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 8)
            }
            HStack {
                Text(picked.isEmpty ? "↑↓ to choose · Return to open · ⌘Return to add someone" : "⌘Return to add someone · Return to message the group")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Open" : "Message \(picked.count == 1 ? picked[0].name : "\(picked.count) people")") { choose() }
                    .keyboardShortcut(.defaultAction).disabled(working)
                Button("") { if case .person(let person)? = current { pick(person) } }.keyboardShortcut(.return, modifiers: .command).hidden().frame(width: 0)
            }.padding(12)
        }.frame(width: 520)
            .task(id: query) {
                problem = nil
                let text = query.trimmingCharacters(in: .whitespaces)
                guard newChat || !text.isEmpty else { people = []; spaces = []; selected = results.items.first?.id; return }
                selected = results.items.first?.id
                try? await Task.sleep(for: .milliseconds(250))   // one search per pause in typing, not per keystroke
                guard !Task.isCancelled else { return }
                searching = true
                defer { searching = false }
                async let foundPeople = store.searchPeople(text)
                async let foundSpaces = store.browseSpaces(text)
                do { people = try await foundPeople } catch { people = []; problem = error.localizedDescription }
                do { spaces = try await foundSpaces } catch { spaces = []; problem = problem ?? error.localizedDescription }
                guard !Task.isCancelled else { return }
                if selected == nil || !results.items.contains(where: { $0.id == selected }) { selected = results.items.first?.id }
            }
    }
    private func row(_ item: PaletteResults.Item, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }.padding(.vertical, 2).contentShape(Rectangle()).tag(item.id)
            .onTapGesture { selected = item.id; choose() }
    }
    private var current: PaletteResults.Item? { results.items.first { $0.id == selected } }
    private func move(_ step: Int) {
        let items = results.items
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.id == selected }.map { $0 + step } ?? 0
        selected = items[min(max(index, 0), items.count - 1)].id
    }
    private func pick(_ person: Person) {
        picked.append(person)
        query = ""
    }
    private func choose() {
        let item = current
        guard !working, !picked.isEmpty || item != nil else { return }
        working = true; problem = nil
        Task {
            defer { working = false }
            do {
                switch item {
                case .person(let person)?: try await store.message(picked + [person])
                case _ where !picked.isEmpty: try await store.message(picked)
                case .conversation(let room)?: await store.select(room.id)
                case .space(let space)?: try await store.join(space)
                case nil: return
                }
                if let then, let id = store.selectedID { then(id) }
                dismiss()
            } catch { problem = error.localizedDescription }
        }
    }
}
