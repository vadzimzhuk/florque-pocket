import Foundation
import FoundationModels

/// Apple Foundation Models adapter with two modes, decided here rather than by a router:
/// - on-device: `SystemLanguageModel.default` (Apple Intelligence, no network)
/// - cloud: Private Cloud Compute, reusing the on-device transcript so the escalated turn keeps context.
///
/// `auto` tries on-device and escalates to cloud when on-device fails.
/// Cloud mode needs an SDK that provides `PrivateCloudComputeLanguageModel`; build with
/// `POCKET_PCC` set once it is available. Without it, cloud calls fail with a clear message.
actor FoundationModelsAdapter: ModelAdapter {
    enum Failure: Error, CustomStringConvertible {
        case onDeviceUnavailable(String)
        case cloudNotCompiled

        var description: String {
            switch self {
            case .onDeviceUnavailable(let reason): "Apple on-device model unavailable: \(reason)"
            case .cloudNotCompiled: "Private Cloud Compute is not in this build (set POCKET_PCC with an SDK that has it)"
            }
        }
    }

    /// Transcript of the last on-device session; the cloud escalation continues from it.
    private var lastTranscript: Transcript?

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
                print(error)
                return try await cloud(system: system, user: user)
            }
        }
    }

    private func onDevice(system: String, user: String) async throws -> ModelReply {
        let model = SystemLanguageModel.default
        let availability = model.availability

        guard case .available = availability else {
            throw Failure.onDeviceUnavailable("\(availability)")
        }
        let session = LanguageModelSession(model: model, instructions: system)
        let started = Date()
        let response = try await session.respond(to: user)
        lastTranscript = session.transcript
        return ModelReply(text: response.content, route: .onDevice, modelName: "apple-foundation-model",
                          seconds: Date().timeIntervalSince(started))
    }

    private func cloud(system: String, user: String) async throws -> ModelReply {
        #if POCKET_PCC
        let started = Date()
        let session: LanguageModelSession
        if let transcript = lastTranscript {
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), transcript: transcript)
        } else {
            session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: system)
        }
        let response = try await session.respond(to: user)
        lastTranscript = session.transcript
        return ModelReply(text: response.content, route: .cloud, modelName: "private-cloud-compute",
                          seconds: Date().timeIntervalSince(started))
        #else
        throw Failure.cloudNotCompiled
        #endif
    }
}
