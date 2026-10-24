import DatabaseAccess
import DatabaseWire

actor DirectoryTestEndpoint: DatabaseExecuting {
    let number: Int32
    let closeGate: QueryExchangeGate?
    private(set) var closeCount = 0
    private(set) var inputs: [QueryInput] = []
    private(set) var parameters: [QueryParameter] = []
    private(set) var options = QueryExecutionOptions()
    private(set) var metadata = OperationRequestMetadata()

    init(_ number: Int32 = 1, closeGate: QueryExchangeGate? = nil) {
        self.number = number; self.closeGate = closeGate
    }
    func execute(_ input: QueryInput, parameters: [QueryParameter], options: QueryExecutionOptions,
        metadata: OperationRequestMetadata) async throws -> AccessResult {
        inputs.append(input); self.parameters = parameters; self.options = options; self.metadata = metadata
        return .rows(try RowStream(page: page(number)))
    }
    func close() async {
        closeCount += 1
        if let closeGate { await closeGate.hold() }
    }
}
