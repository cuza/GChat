import AppKit
import SwiftUI
import WebKit

extension SignInFlow.Phase {
    var status: String {
        switch self {
        case .opening: "Opening Google sign-in…"
        case .waiting: "Waiting for you to sign in…"
        case .finishing: "Finishing…"
        case .idle, .signedIn: ""
        }
    }
}

/// Fills the main window while there is no session.
struct WelcomeView: View {
    let flow: SignInFlow
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 112, height: 112).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Sign in to Google Chat").font(.largeTitle.weight(.semibold))
                Text("Your conversations, spaces and messages, in a native Mac app.").foregroundStyle(.secondary)
            }
            Group {
                if flow.busy { SignInProgress(flow: flow) }
                else {
                    VStack(spacing: 10) {
                        Button { flow.start() } label: { Text("Sign in with Google").frame(minWidth: 220) }
                            .buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                        Text(WebSignInSheet.passkeyNote).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.frame(minHeight: 90, alignment: .top)
            if let error = flow.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(.center).frame(maxWidth: 440).padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
}

/// The steps of a running sign-in, with the manual fallback and Cancel.
struct SignInProgress: View {
    let flow: SignInFlow
    var compact = false
    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 12))
        layout {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.phase.status).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            HStack(spacing: 8) {
                if flow.offerManual {
                    Button("I've Signed In") { Task { await flow.confirm() } }.disabled(flow.phase != .waiting)
                }
                Button("Cancel", role: .cancel) { flow.cancel() }.keyboardShortcut(compact ? nil : .cancelAction)   // the composer keeps Escape
            }
        }
        .animation(.default, value: flow.phase)
    }
}

/// Over the conversations when the session ends while in use; signing in again picks up where it left off.
struct SessionExpiredBanner: View {
    let flow: SignInFlow
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark").font(.title3).foregroundStyle(.orange)
            if flow.busy {
                SignInProgress(flow: flow, compact: true)
                Spacer()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Google session expired").font(.headline)
                    Text(flow.error ?? "Your messages and drafts are kept.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Sign In Again") { flow.start() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Shows the sign-in sheet while the in-app sign-in runs; closing the sheet cancels the sign-in.
struct WebSignInPresenter: ViewModifier {
    let flow: SignInFlow
    let web: WebViewSignIn
    func body(content: Content) -> some View {
        let shown = web.presented
        content.sheet(isPresented: Binding(get: { shown }, set: { if !$0 { flow.cancel() } })) {
            WebSignInSheet(flow: flow, web: web)
        }
    }
}

/// Google's sign-in pages. Once Google hands the session to Google Chat, its website is covered by progress.
struct WebSignInSheet: View {
    static let passkeyNote = "Passkeys aren't available here — choose Try another way."
    let flow: SignInFlow
    let web: WebViewSignIn
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in with Google").font(.headline)
                    Text(Self.passkeyNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { flow.cancel() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ZStack {
                if let view = web.webView { WebViewHost(view: view) }
                if web.handingOff {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(flow.phase == .finishing ? "Finishing…" : "Connecting to Google Chat…").foregroundStyle(.secondary)
                        if let error = flow.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
        }
        .frame(width: 520, height: 680)
    }
}

private struct WebViewHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
