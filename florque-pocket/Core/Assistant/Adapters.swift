import Foundation

// Purpose: the seams to the outside world: the language model and the system reminders. The app implements
// them with Apple Foundation Models or Firebase, and with EventKit. Tests substitute scripted fakes.
// Testing: `AssistantTests` and the eval suites use fakes for both, so no test needs a network or EventKit.

/// Where a reply was produced.
public enum Route: String, Sendable, Equatable {
    case onDevice
    case cloud
}

/// User-selectable routing. `auto` uses the hybrid model and escalates to cloud after failures.
public enum RoutePolicy: String, Sendable, CaseIterable, Equatable {
    case auto
    case forceOnDevice
    case forceCloud
}

public struct ModelReply: Sendable, Equatable {
    public var text: String
    public var route: Route
    public var modelName: String
    public var seconds: Double

    public init(text: String, route: Route, modelName: String, seconds: Double) {
        self.text = text; self.route = route; self.modelName = modelName; self.seconds = seconds
    }
}

/// Adapter over a language model. Each adapter decides internally how to serve a policy
/// (on-device, cloud, or fallback between them). Apps implement it with Apple Foundation Models or Firebase AI Logic.
public protocol ModelAdapter: Sendable {
    func generate(system: String, user: String, policy: RoutePolicy) async throws -> ModelReply
}

/// Adapter over the system reminders. The app implements it with EventKit.
public protocol RemindersAdapter: Sendable {
    /// Creates a reminder and returns its identifier.
    func createReminder(title: String, due: Date) async throws -> String
}

