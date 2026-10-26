import SwiftUI
import Foundation

@main
@MainActor
struct AetherMixApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(.white)
        }
    }
}
