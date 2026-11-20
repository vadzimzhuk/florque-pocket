//Copyright © 2026 Vadim Zhuk

import SwiftUI
import FirebaseCore
import FirebaseAppCheck

@main
struct florque_pocketApp: App {
    @State private var chat: ChatViewModel

    init() {
        #if DEBUG
        // Debug builds use an App Check debug token (register it in the Firebase console).
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #endif
        FirebaseApp.configure()
        let vm = ChatViewModel.makeDefault()
        #if DEBUG
        // Test hooks: `-backend apple|firebase`, `-policy auto|forceOnDevice|forceCloud`, `-autoSend "text"`.
        if let i = CommandLine.arguments.firstIndex(of: "-policy"), i + 1 < CommandLine.arguments.count,
           let p = RoutePolicy(rawValue: CommandLine.arguments[i + 1]) {
            vm.policy = p
        }
        if let i = CommandLine.arguments.firstIndex(of: "-backend"), i + 1 < CommandLine.arguments.count,
           let b = ChatViewModel.Backend(rawValue: CommandLine.arguments[i + 1]) {
            vm.backend = b
        }
        if let i = CommandLine.arguments.firstIndex(of: "-autoSend"), i + 1 < CommandLine.arguments.count {
            let text = CommandLine.arguments[i + 1]
            Task { @MainActor in vm.send(text) }
        }
        #endif
        _chat = State(initialValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            ChatScreen(vm: chat)
        }
    }
}
