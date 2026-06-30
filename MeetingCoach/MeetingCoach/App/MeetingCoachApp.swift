import SwiftUI

@main
struct MeetingCoachApp: App {
    @State private var ollamaManager = OllamaManager()

    var body: some Scene {
        WindowGroup {
            ContentView(ollamaManager: ollamaManager)
            // Ollama is no longer auto-started on launch.
            // It will be started lazily when post-call review is requested
            // or when running the legacy LLM-based simulation.
        }
        .defaultSize(width: 960, height: 640)
    }
}
