/// An incomplete page cannot be exposed as a complete local result.
public enum StreamAdaptationError: Error, Sendable, Equatable {
    case missingPageSource
}
