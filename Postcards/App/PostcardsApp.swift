import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

@main
struct PostcardsApp: App {
    @State private var library = LibraryModel()
    @State private var cloudLibrary = CloudLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library, cloudLibrary: cloudLibrary)
                .task { await cloudLibrary.start() }
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        #endif
    }

    #if os(macOS)
    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose .postcards collections or .postcard image files"
        // .postcard.webp etc (the card format) are still compound extensions LaunchServices
        // can't express, so allow the base types and let LibraryModel validate the full
        // suffix. Collections use the single-segment .postcards extension (exported UTI
        // org.dotpostcard.postcards, which conforms to public.database).
        panel.allowedContentTypes = [.database, .data, .image]

        let library = library
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                await library.importSources(from: urls)
            }
        }
    }
    #endif
}
