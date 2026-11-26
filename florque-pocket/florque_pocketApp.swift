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
        #if DEBUG
        // Test hooks: `-backend apple|firebase`, `-workflow cer`, `-policy auto|forceOnDevice|forceCloud`, `-autoSend "text"`.
        func argument(_ name: String) -> String? {
            guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[i + 1]
        }
        let backend = argument("-backend").flatMap(ChatViewModel.Backend.init(rawValue:)) ?? .apple
        let workflow = argument("-workflow").flatMap(WorkflowID.init(rawValue:)) ?? .cer
        #else
        let backend = ChatViewModel.Backend.apple
        let workflow = WorkflowID.cer
        #endif
        let vm = ChatViewModel.makeDefault(backend: backend, workflow: workflow)
        #if DEBUG
        if let p = argument("-policy").flatMap(RoutePolicy.init(rawValue:)) {
            vm.policy = p
        }
        if let text = argument("-autoSend") {
            Task { @MainActor in vm.send(text) }
        }
        #endif
        _chat = State(initialValue: vm)
    }

    var body: some Scene {
        WindowGroup {
            RootView(chat: chat)
        }
    }
}
