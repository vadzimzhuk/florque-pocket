import SwiftUI

// Purpose: the app's root: a tab bar with the chat and the Memory tab. Settings opens from the chat's toolbar.
//
// Testing: manual on a simulator (both tabs open, and the Memory list shows what the chat saved).

struct RootView: View {
    let chat: ChatViewModel

    var body: some View {
        TabView {
            ChatScreen(vm: chat)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            MemoryScreen(store: chat.memoryStore)
                .tabItem { Label("Memory", systemImage: "brain") }
        }
    }
}
