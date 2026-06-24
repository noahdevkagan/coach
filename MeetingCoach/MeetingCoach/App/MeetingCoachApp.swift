import SwiftUI

@main
struct MeetingCoachApp: App {
    @State private var ollamaManager = OllamaManager()

    var body: some Scene {
        WindowGroup {
            ContentView(ollamaManager: ollamaManager)
                .task {
                    ollamaManager.start()
                }
        }
        .defaultSize(width: 960, height: 640)
    }
}
