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
        content
            // The browser opens once the sheet has gone, so the two never compete to present.
            .sheet(isPresented: $isPresented, onDismiss: startSignIn) {
                HandleEntry(handle: $handle) { submit in
                    if submit { submittedHandle = handle }
                    isPresented = false
                }
            }
            .alert(
                accounts.problem?.title ?? "",
                isPresented: Binding(get: { accounts.problem != nil }, set: { if !$0 { accounts.problem = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(accounts.problem?.message ?? "")
            }
    }

    private func startSignIn() {
        guard let submittedHandle else { return }
        self.submittedHandle = nil
        handle = ""
        let openBrowser = webAuthenticationSession.userAuthenticator(preferredBrowserSession: .ephemeral)
        Task { await accounts.signIn(handle: submittedHandle, openBrowser: openBrowser) }
    }
}

private struct HandleEntry: View {
    @Binding var handle: String
    /// `true` to continue, `false` to cancel.
    let finish: (Bool) -> Void

    private var canContinue: Bool { !handle.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account")
                .font(.headline)
            TextField("alice.bsky.social", text: $handle)
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
                #endif
                .onSubmit { if canContinue { finish(true) } }
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
        #if os(macOS)
        .frame(width: 320)
        #else
        .presentationDetents([.height(180)])
        #endif
    }
}
