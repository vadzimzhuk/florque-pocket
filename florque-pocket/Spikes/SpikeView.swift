import SwiftUI

/// Debug screen for the Phase 0 spikes. Replaced by the chat screen in Phase 2.
struct SpikeView: View {
    @State private var prompt = "Remind me to call the landlord Friday morning."
    @State private var output = "Not run yet."
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("S1/S2 Hybrid call") {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                    Button("Run hybrid call") { Task { await runHybrid() } }
                        .disabled(busy)
                }
                Section("Result") {
                    Text(output).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle("Pocket spikes")
        }
    }

    @MainActor
    private func runHybrid() async {
        busy = true
        defer { busy = false }
        do {
            let r = try await HybridSpike.run(userText: prompt)
            output = """
            route: \(r.routeLabel)
            on-device available: \(r.onDeviceAvailable)
            seconds: \(String(format: "%.2f", r.seconds))
            committed: \(r.committed)
            issues: \(r.issues.isEmpty ? "none" : r.issues.joined(separator: "; "))

            \(r.text)
            """
        } catch {
            output = "Error: \(error)"
        }
    }
}
