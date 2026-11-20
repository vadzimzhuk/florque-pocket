import SwiftUI
import ExyteChat

/// Chat-only screen. exyte/Chat renders the conversation; route badges and Accept/Dismiss sit
/// under assistant messages. Swap the library here without touching the view model.
struct ChatScreen: View {
    @State var vm: ChatViewModel

    var body: some View {
        NavigationStack {
            ChatView(messages: vm.messages, didSendMessage: { draft in
                vm.send(draft.text)
            }, messageBuilder: { params in
                let entryId = params.message.customData["entryId"] as? String ?? ""
                VStack(alignment: .leading, spacing: 8) {
                    params.defaultMessageView()
                    if let entry = vm.entries.first(where: { $0.id == entryId }), !entry.proposals.isEmpty {
                        ForEach(entry.proposals, id: \.id) { proposal in
                            HStack {
                                Text(proposal.title).font(.footnote)
                                Spacer()
                                Button("Dismiss") { vm.dismiss(proposal, in: entryId) }
                                    .buttonStyle(.bordered)
                                Button("Accept") { vm.accept(proposal, in: entryId) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            })
            // Text and media only: without audio, exyte shows the send button, not the mic, when the composer is empty.
            .setAvailableInputs([.text, .media])
            .navigationTitle("Pocket")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Backend", selection: $vm.backend) {
                            Text("Apple Foundation Models").tag(ChatViewModel.Backend.apple)
                            Text("Firebase AI Logic").tag(ChatViewModel.Backend.firebase)
                        }
                        Picker("Route", selection: $vm.policy) {
                            Text("Auto").tag(RoutePolicy.auto)
                            Text("On-device only").tag(RoutePolicy.forceOnDevice)
                            Text("Cloud only").tag(RoutePolicy.forceCloud)
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                }
            }
        }
    }
}
