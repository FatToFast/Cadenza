import SwiftUI

@main
struct CadenzaApp: App {
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        WindowGroup {
            PlayerView()
                .environmentObject(audioManager)
                .preferredColorScheme(.dark)
        }
    }
}
