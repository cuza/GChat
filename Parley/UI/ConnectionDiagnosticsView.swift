import AppKit
import SwiftUI

/// Settings ▸ Advanced ▸ Connection Diagnostics: account, realtime channel, saved session and read checks.
struct ConnectionDiagnosticsView: View {
    let store: ChatStore
    @Environment(SignInFlow.self) private var signIn: SignInFlow?
    @State private var model: ConnectionDiagnostics
    @State private var confirmSignOut = false
    @State private var accountError: String?
    @State private var copied = false

    init(store: ChatStore, authorizer: WebSessionAuthorizer) {
        self.store = store
        _model = State(initialValue: ConnectionDiagnostics(authorizer: authorizer))
    }

    /// Offline with a saved session still counts: signing out is what's offered.
    private var signedIn: Bool { store.connection != .signedOut && (!store.me.id.isEmpty || model.stored == true) }

    var body: some View {
        Form {
            account
            connection
            session
            checks
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(minWidth: 520, minHeight: 560)
        .task { model.refresh() }
        .onChange(of: store.connection) { model.refresh() }
        .confirmationDialog("Sign out of Google Chat?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) {
                Task {
                    do {
                        try await signIn?.signOut()
                        store.signedOut()
                        accountError = nil
                    } catch { accountError = error.localizedDescription }
                    model.refresh()
                }
            }
        } message: { Text("Parley forgets this Google session. Your drafts stay on this Mac.") }
    }

    private var account: some View {
        Section("Account") {
            HStack(spacing: 12) {
                if store.me.id.isEmpty {
                    Image(systemName: "person.crop.circle").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Not signed in").foregroundStyle(.secondary)
                } else {
                    Avatar(name: store.me.name, size: 40, url: store.me.avatarURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.me.name).font(.headline)
                        if let email = store.me.email { Text(email).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Spacer()
                StatusBadge(status: ConnectionDiagnostics.status(store.connection))
            }
            .padding(.vertical, 2)
            LabeledContent("Session saved in Keychain") {
                let indicator = model.indicator
                Label(indicator.title, systemImage: indicator.symbol).foregroundStyle(indicator.color)
            }
            if let flow = signIn, flow.busy {
                SignInProgress(flow: flow, compact: true)
            } else {
                HStack {
                    if let error = accountError ?? signIn?.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    }
                    Spacer()
                    if signedIn {
                        // The silent renewal on demand: what Parley does by itself when Google ends the session.
                        Button("Renew Session") {
                            Task { if await signIn?.renewSilently(force: true) == true { model.refresh() } else { accountError = "Google wants you to sign in again." } }
                        }.disabled(signIn?.renewer == nil)
                        Button("Sign Out…") { confirmSignOut = true }.disabled(signIn == nil)
                    } else {
                        Button("Sign In…") { signIn?.start() }.disabled(signIn == nil)
                    }
                }
            }
        }
    }

    private var connection: some View {
        Section("Connection") {
            LabeledContent("Realtime channel") {
                let status = ConnectionDiagnostics.status(store.connection)
                Label(status.title, systemImage: "dot.radiowaves.left.and.right").foregroundStyle(status.color)
            }
            LabeledContent("Connected since") {
                if let since = store.connectedSince { Text(since.formatted(date: .abbreviated, time: .shortened)) } else { Text("—") }
            }
            LabeledContent("Last event received") {
                if let last = store.lastEventAt { Text("\(Text(last, style: .relative)) ago") } else { Text("None yet") }
            }
            LabeledContent("Reconnects", value: store.reconnects, format: .number)
            LabeledContent("Conversations") { Text("\(store.conversations.count) · \(store.unreadCount) unread") }
            HStack {
                Spacer()
                Button("Reconnect") { Task { await store.start() } }
                    .disabled(store.me.id.isEmpty || store.connection == .signedOut || store.connection == .connecting)
            }
        }
    }

    @ViewBuilder private var session: some View {
        Section("Session") {
            if model.cookies.isEmpty {
                Text(model.vaultError ?? "No session saved.").foregroundStyle(.secondary)
            } else {
                LabeledContent("Cookies", value: model.cookies.count, format: .number)
                LabeledContent("Earliest expiry") {
                    if let date = model.earliestExpiry { Text(date.formatted(date: .abbreviated, time: .shortened)) } else { Text("When the session ends") }
                }
                DisclosureGroup("Cookie names") {
                    ForEach(model.cookies) { cookie in
                        LabeledContent {
                            Text(cookie.expires?.formatted(date: .abbreviated, time: .omitted) ?? "Session")
                        } label: {
                            Text(cookie.name).font(.body.monospaced())
                            Text(cookie.domain)
                        }
                    }
                }
            }
        }
    }

    private var checks: some View {
        Section {
            if model.checks.isEmpty {
                Text("Reads your identity and conversation list. Nothing is sent or changed.").foregroundStyle(.secondary)
            }
            ForEach(model.checks) { check in
                LabeledContent {
                    Text(check.durationText).monospacedDigit()
                } label: {
                    Label {
                        Text(check.name)
                        Text(check.message)
                    } icon: {
                        Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.passed ? .green : .red)
                    }
                }
            }
        } header: {
            HStack {
                Text("Checks")
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Run Checks") { Task { await model.runChecks() } }.disabled(model.running)
            }
        }
    }

    private var footer: some View {
        HStack {
            if copied { Label("Copied", systemImage: "checkmark").foregroundStyle(.secondary).transition(.opacity) }
            Spacer()
            Button("Save Log…", systemImage: "square.and.arrow.down") { saveLog() }
            Button("Copy Diagnostics", systemImage: "doc.on.doc") { copy() }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// A .log file to send with a bug report: this summary, this launch's log and recent crash reports.
    private func saveLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Parley \(Date.now.formatted(.iso8601.year().month().day())).log"
        panel.allowedContentTypes = [.log]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = DiagnosticsLog.text(summary: report.text, log: DiagnosticsLog.entries(), crashes: DiagnosticsLog.crashes())
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { accountError = error.localizedDescription }
    }
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { copied = false }
        }
    }
    private var report: ConnectionDiagnostics.Report {
        let info = Bundle.main.infoDictionary
        return ConnectionDiagnostics.Report(
            app: "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            connection: store.connection, connectedSince: store.connectedSince, lastEvent: store.lastEventAt,
            reconnects: store.reconnects, conversations: store.conversations.count, unread: store.unreadCount,
            signedIn: signedIn, signInMethod: UserDefaults.standard.string(forKey: SignInFlow.methodKey), stored: model.stored, cookies: model.cookies, checks: model.checks,
            errors: [store.error, accountError, signIn?.error, model.vaultError].compactMap { $0 }, now: .now)
    }
}

/// A colored dot and the state's name, like System Settings' status rows.
struct StatusBadge: View {
    let status: ConnectionDiagnostics.Status
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            Text(status.title).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(status.color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
