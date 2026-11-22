import SwiftUI

@main
struct VirtualPCApp: App {
    @StateObject private var library = VMLibraryStore()
    @StateObject private var isoLibrary = ISOLibrary()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(library)
                .environmentObject(isoLibrary)
                .preferredColorScheme(nil) // follow the system; this is how "dark mode and an optional light mode" is satisfied
        }
    }
}
