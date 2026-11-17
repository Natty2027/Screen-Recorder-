import SwiftUI

@main struct MyApp: App {
    @State private var recorder = ScreenRecorder()

    var body: some Scene {
        Window("Screen Recorder", id: "main") {
            ContentView()
                .environment(recorder)
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Recording", id: "player", for: URL.self) { $url in
            if let url {
                PlayerView(url: url)
                    .environment(recorder)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(recorder)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
    }
}
