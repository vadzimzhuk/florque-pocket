import Foundation

// Purpose: one global logger for debug output. A line is printed to the Xcode console as "[category] message".
// Debug lines are printed only in DEBUG builds; release builds print nothing and do not evaluate the message.
// Usage: Log.debug("intent", "step saveNote start")
//
// Testing: the logger has no logic beyond formatting and the DEBUG check, so it is verified by running the app
// in a DEBUG build and reading the console (the workflow logs each step and the state after it).

nonisolated enum Log {
    /// Prints one debug line. The message is built only when it is printed.
    static func debug(_ category: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(category)] \(message())")
        #endif
    }
}
