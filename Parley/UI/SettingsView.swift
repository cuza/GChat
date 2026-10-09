import UserNotifications
import SwiftUI

/// Settings ▸ Appearance: follow macOS, or keep Parley light or dark.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark
    static let key = "appearance"
    @MainActor static func apply() {
        let mode = UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .auto
        NSApplication.shared.appearance = mode == .auto ? nil : NSAppearance(named: mode == .light ? .aqua : .darkAqua)
    }
}

/// The colour well for one appearance's bubbles. It holds its own colour: bound straight to the stored hex, the panel's
/// Display P3 colour never matched the sRGB read back, so each answer re-saved it and the panel never settled.
struct BubbleColorPicker: View {
    @Binding var hex: String
    @State private var color: Color
    init(hex: Binding<String>) {
        _hex = hex
        _color = State(initialValue: Color(nsColor: NSColor(hex: hex.wrappedValue) ?? .controlAccentColor))
    }
    var body: some View {
        ColorPicker("Bubble colour", selection: $color, supportsOpacity: false)
            .labelsHidden().help("Your bubbles")
            .task(id: color) {   // saved once the colour stops moving, so a drag doesn't redraw every row on every step
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let change = Self.change(from: hex, to: color) else { return }
                hex = change
            }
            .onChange(of: hex) { if Self.change(from: hex, to: color) != nil { color = Color(nsColor: NSColor(hex: hex) ?? .controlAccentColor) } }
    }
    /// The hex to save for `picked`, or nil when it rounds to the one already stored.
    static func change(from stored: String, to picked: Color) -> String? {
        guard let hex = NSColor(picked).hex, hex != stored else { return nil }
        return hex
    }
}

/// Parley ▸ Settings (⌘,).
struct SettingsView: View {
    let store: ChatStore
    @Environment(SignInFlow.self) private var signIn: SignInFlow?
    @Environment(\.openWindow) private var openWindow
    @State private var confirmSignOut = false
    @State private var accountError: String?
    @AppStorage("timelineStyle") private var style = TimelineStyle.bubbles
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.auto
    @AppStorage(Wallpaper.key(dark: false)) private var wallpaper = Wallpaper.none
    @AppStorage(Wallpaper.key(dark: true)) private var darkWallpaper = Wallpaper.none
    @AppStorage(Wallpaper.doodlesKey) private var doodles = true
    @AppStorage(BubblePalette.colorKey(dark: false)) private var bubbleColor = ""
    @AppStorage(BubblePalette.colorKey(dark: true)) private var darkBubbleColor = ""
    @State private var giphyKey = Giphy.key ?? ""
    @State private var keyError: String?
    @AppStorage(NotificationSettings.enabledKey) private var notify = true
    @AppStorage(NotificationSound.key) private var sound = NotificationSound.standard.stored
    @State private var sounds = NotificationSound.available()
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined
    @MainActor private static var playing: NSSound?
    private static func play(_ sound: NotificationSound) {
        playing?.stop()   // one at a time, as System Settings plays them
        playing = sound.preview
        playing?.play()
    }
    /// One appearance's wallpaper and bubble colour.
    private func look(_ title: String, wallpaper: Binding<Wallpaper>, bubble: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Picker("Wallpaper", selection: wallpaper) {
                    ForEach(Wallpaper.allCases, id: \.self) { Text($0 == .none ? "No Wallpaper" : $0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().fixedSize()
                BubbleColorPicker(hex: bubble)
                Button("Reset") { bubble.wrappedValue = "" }.disabled(bubble.wrappedValue.isEmpty)
                    .help("Use the accent colour").accessibilityLabel("Use the accent colour")
            }
        }
    }
    var body: some View {
        Form {
            LabeledContent("Account") {
                if store.me.id.isEmpty {
                    Text("Not signed in").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Avatar(name: store.me.name, size: 36, url: store.me.avatarURL)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.me.name).font(.headline)
                            if let email = store.me.email { Text(email).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Sign Out…") { confirmSignOut = true }.disabled(signIn == nil)
                    }
                }
            }
            if let accountError { Text(accountError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Picker("Appearance", selection: $appearance) {
                Text("Auto").tag(AppearanceMode.auto)
                Text("Light").tag(AppearanceMode.light)
                Text("Dark").tag(AppearanceMode.dark)
            }
            .pickerStyle(.segmented).fixedSize()
            .onChange(of: appearance) { AppearanceMode.apply() }
            look("Light mode", wallpaper: $wallpaper, bubble: $bubbleColor)
            look("Dark mode", wallpaper: $darkWallpaper, bubble: $darkBubbleColor)
            Toggle("Doodles over the wallpaper", isOn: $doodles).disabled(wallpaper == .none && darkWallpaper == .none)
            Text("Wallpaper and the colour of your bubbles, for each appearance. Text on your bubbles turns white or black, whichever reads better on the colour.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // wraps instead of truncating
            Picker("Message style", selection: $style) {
                Text("Bubbles").tag(TimelineStyle.bubbles)
                Text("Plain").tag(TimelineStyle.plain)
            }
            .pickerStyle(.radioGroup)
            Text("Plain lists every message on the left, with names and avatars, like Telegram's list mode.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // wraps instead of truncating
            Divider()
            Toggle("Show notifications", isOn: $notify)
                .onChange(of: notify) { _, on in if on { Task { notificationStatus = await SystemNotifier.requestAuthorization() } } }
                .task { notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
            // As System Settings ▸ Sound offers its alert sound: the Mac's sounds, the choice played, a button to hear it again.
            LabeledContent("Sound") {
                HStack {
                    Picker("Sound", selection: $sound) { ForEach(sounds, id: \.self) { Text($0.name).tag($0.stored) } }
                        .labelsHidden().fixedSize()
                        .onChange(of: sound) { _, sound in Self.play(NotificationSound(stored: sound)) }
                    Button { Self.play(NotificationSound(stored: sound)) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Play the sound").disabled(NotificationSound(stored: sound).preview == nil)
                }
            }
            .disabled(!notify)
            Text(NotificationSound(stored: sound).playedByParley
                 ? "Parley plays this sound itself, during Focus too, as Slack does: macOS plays only its default sound for apps."
                 : "macOS plays its default sound, following your Focus and notification settings.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // wraps instead of truncating
            if notify, notificationStatus == .denied {
                HStack {
                    Text("macOS isn't letting Parley show notifications.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }.controlSize(.small)
                }
            }
            Text("Each conversation notifies as set in its Notifications menu, the same setting web and mobile Chat use. Muted conversations never notify. Banners and sounds are also set in System Settings ▸ Notifications.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // wraps instead of truncating
            Divider()
            SecureField("GIPHY API key", text: $giphyKey)
                .onChange(of: giphyKey) { _, key in
                    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    do {
                        try Giphy.keyItem.set(key)
                        keyError = nil
                    } catch { keyError = error.localizedDescription }
                }
            Text(keyError ?? "For the composer's GIF picker. Create one at developers.giphy.com. It is kept in your Keychain.")
                .font(.caption).foregroundStyle(keyError == nil ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true)
            Divider()
            LabeledContent("Advanced") {
                Button("Connection Diagnostics…") { openWindow(id: "connection-diagnostics") }
            }
            Text("Connection status, the saved session and read checks, with a report to copy.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)   // wraps instead of truncating
        }
        .confirmationDialog("Sign out of Google Chat?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    do {
                        try await signIn?.signOut()
                        store.signedOut()
                        accountError = nil
                    } catch { accountError = error.localizedDescription }
                }
            }
        } message: { Text("Parley forgets this Google session. Your drafts stay on this Mac.") }
        .padding(20).frame(width: 420)
    }
}
