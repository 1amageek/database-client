/// An invalid or already consumed logical-access configuration.
public enum AccessConfigurationError: Error, Sendable, Equatable {
    case invalidConcurrencyLimit(Int)
    case openingAlreadyUsed
}
