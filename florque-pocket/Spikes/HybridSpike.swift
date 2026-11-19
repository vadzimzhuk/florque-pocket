import Foundation
import FirebaseAI
import OntologyKit

/// Spike S1/S2: does a hybrid call return usable JSON, and can we tell which model answered?
struct HybridResult: Sendable {
    var text: String
    var routeLabel: String
    var onDeviceAvailable: Bool
    var seconds: Double
    var issues: [String]
    var committed: Bool
}

enum HybridSpike {
    static let cloudModelName = "gemini-2.5-flash-lite"

    static func ontology() throws -> Ontology {
        guard let url = Bundle.main.url(forResource: "pocket.linkml", withExtension: "yaml") else {
            throw SpikeError.missingResource
        }
        return try Ontology.load(yaml: String(contentsOf: url, encoding: .utf8))
    }

    static func run(userText: String) async throws -> HybridResult {
        let ont = try ontology()
        let ai = FirebaseAI.firebaseAI()
        let primary = FirebaseAI.SystemLanguageModel.default
        let model = HybridModel(primary: primary, secondary: ai.geminiModel(name: cloudModelName))
        let session = ai.generativeModelSession(
            model: model,
            instructions: """
            You are Pocket, a private note taker. Answer only with the JSON reply described below.
            \(PromptCompiler.ontologyGuide(ont))

            \(PromptCompiler.toolContract())
            """
        )

        let started = Date()
        let response = try await session.respond(to: userText)
        let seconds = Date().timeIntervalSince(started)

        // Heuristic to verify on a device: Gemini names mean cloud, anything else is on-device.
        let version = response.rawResponse.modelVersion
        let isCloud = version.lowercased().contains("gemini")
        let label = (isCloud ? "Cloud · " : "On-device · ") + version

        let executor = ToolExecutor(ontology: ont, store: InMemoryGraphStore())
        let outcome = await executor.run(reply: response.content)

        return HybridResult(text: response.content, routeLabel: label,
                            onDeviceAvailable: primary.isAvailable, seconds: seconds,
                            issues: outcome.issues, committed: outcome.committed)
    }

    enum SpikeError: Error { case missingResource }
}
