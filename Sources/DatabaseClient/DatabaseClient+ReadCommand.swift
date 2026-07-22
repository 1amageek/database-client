import DatabaseWire

extension DatabaseClient {
    public func executeReadCommand<Command: DatabaseReadCommandDescriptor>(
        _ command: Command.Type,
        input: Command.Input,
        budget: DatabaseExecutionBudget = DatabaseExecutionBudget(),
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> DatabaseTypedReadCommandResponse<Command.Output> {
        try await execute(
            DatabaseTypedReadCommandOperation<Command>.self,
            request: DatabaseTypedCommandRequest<Command>(
                input: input,
                budget: budget
            ),
            metadata: metadata
        )
    }
}
