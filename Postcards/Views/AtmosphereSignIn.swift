import AuthenticationServices
import SwiftUI

/// "Add Account": asks for a handle, then runs the atproto OAuth sign-in in the system web
/// authentication session. Also shows any sign-in/sign-out problem.
struct AtmosphereSignIn: ViewModifier {
    let accounts: AtmosphereAccounts
    @Binding var isPresented: Bool

    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var handle = ""
    @State private var submittedHandle: String?

    func body(content: Content) -> some View {
        handleEntry(content)
            // On a background view: two alerts on one view don't reliably both present.
            .background {
                Color.clear.alert(
                    accounts.problem?.title ?? "",
                    isPresented: Binding(get: { accounts.problem != nil }, set: { if !$0 { accounts.problem = nil } })
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(accounts.problem?.message ?? "")
                }
            }
    }

    @ViewBuilder
    private func handleEntry(_ content: Content) -> some View {
        #if os(macOS)
        // The browser opens once the sheet has gone, so the two never compete to present.
        content.sheet(isPresented: $isPresented, onDismiss: startSignIn) {
            HandleEntry(handle: $handle) { submit in
                if submit { submittedHandle = handle }
                isPresented = false
            }
        }
        #else
        content
            .alert("Your Atmosphere account", isPresented: $isPresented) {
                TextField("alice.bsky.social", text: $handle)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Cancel", role: .cancel) {}
                Button("Continue") { submittedHandle = handle }
                    .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Any Atmosphere account works (including Bluesky)")
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                Task {
                    // Lets the alert finish leaving before the browser presents.
                    try? await Task.sleep(for: .milliseconds(400))
                    startSignIn()
                }
            }
        #endif
    }

    private func startSignIn() {
        guard let submittedHandle else {
            handle = ""
            return
        }
        self.submittedHandle = nil
        handle = ""
        let openBrowser = webAuthenticationSession.userAuthenticator(preferredBrowserSession: .ephemeral)
        Task { await accounts.signIn(handle: submittedHandle, openBrowser: openBrowser) }
    }
}

#if os(macOS)
private struct HandleEntry: View {
    @Binding var handle: String
    /// `true` to continue, `false` to cancel.
    let finish: (Bool) -> Void

    private var canContinue: Bool { !handle.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Atmosphere account")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TextField("alice.bsky.social", text: $handle)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .onSubmit { if canContinue { finish(true) } }
                Text("Any Atmosphere account works (including Bluesky)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
#endif
