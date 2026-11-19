//Copyright © 2026 Vadim Zhuk

import SwiftUI
import FirebaseCore
import FirebaseAppCheck

@main
struct florque_pocketApp: App {
    init() {
        #if DEBUG
        // Debug builds use an App Check debug token. Register the token printed in the
        // Xcode console under App Check in the Firebase console.
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #endif
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            SpikeView()
        }
    }
}
