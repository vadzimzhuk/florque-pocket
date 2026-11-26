import Foundation

// Purpose: the outcome of one checked step: a value that passed its checks, or the reason it was rejected. The `cer`
// steps return it from their parse and process stages, and the state's reducers read it.
// Testing: covered by the `cer` step tests in `CERTests`.

nonisolated enum Checked<Value> {
    case ok(Value)
    case rejected(String)
}
