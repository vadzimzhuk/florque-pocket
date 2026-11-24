import Foundation
import FirebaseAI

/// Firebase AI Logic adapter with the same internal switch as the Apple adapter:
/// - on-device: Apple's system model through Firebase (`FirebaseAI.SystemLanguageModel`)
/// - cloud: Gemini Developer API
/// `auto` tries on-device and falls back to Gemini.
struct FirebaseModelAdapter: ModelAdapter {
    static let cloudModelName = "gemini-2.5-flash-lite"

    private let ai = FirebaseAI.firebaseAI()

    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply {
        switch policy {
        case .forceOnDevice:
            return try await onDevice(system: system, user: user)
        case .forceCloud:
            return try await cloud(system: system, user: user)
        case .auto:
            do {
                return try await onDevice(system: system, user: user)
            } catch {
                return try await cloud(system: system, user: user)
            }
        }
    }

    private func onDevice(system: String, user: String) async throws -> ModelReply {
        let session = ai.generativeModelSession(model: FirebaseAI.SystemLanguageModel.default, instructions: system)
        let started = Date()
        let response = try await session.respond(to: user)
        return ModelReply(text: response.content, route: .onDevice,
                          modelName: response.rawResponse.modelVersion,
                          seconds: Date().timeIntervalSince(started))
    }

    private func cloud(system: String, user: String) async throws -> ModelReply {
        let gemini = ai.geminiModel(name: Self.cloudModelName)
        // Both slots are the cloud model, so this session never runs on-device.
        let session = ai.generativeModelSession(model: HybridModel(primary: gemini, secondary: gemini),
                                                instructions: system)
        let started = Date()
        let response = try await session.respond(to: user)
        return ModelReply(text: response.content, route: .cloud,
                          modelName: response.rawResponse.modelVersion,
                          seconds: Date().timeIntervalSince(started))
    }
}
