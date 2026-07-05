import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

@main
struct PostcardsApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
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
        panel.message = "Choose .postcard.db collections or .postcard image files"
        // .postcard.db / .postcard.webp etc are compound extensions LaunchServices can't
        // express, so allow the base types and let LibraryModel validate the full suffix.
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
