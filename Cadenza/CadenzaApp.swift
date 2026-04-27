import SwiftUI

@main
struct CadenzaApp: App {
    @StateObject private var audioManager = AudioManager()
    @State private var nowPlayingCoordinator: NowPlayingCenterCoordinator?
    @State private var remoteCommandCoordinator: RemoteCommandCoordinator?

    var body: some Scene {
        WindowGroup {
            PlayerView()
                .environmentObject(audioManager)
                .preferredColorScheme(.dark)
                .task {
                    if nowPlayingCoordinator == nil {
                        nowPlayingCoordinator = NowPlayingCenterCoordinator(audio: audioManager)
                    }
                    if remoteCommandCoordinator == nil {
                        remoteCommandCoordinator = RemoteCommandCoordinator(audio: audioManager)
                    }
                }
        }
    }
}
