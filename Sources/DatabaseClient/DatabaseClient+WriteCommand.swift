import DatabaseWire

extension DatabaseClient {
    public func executeWriteCommand<Command: DatabaseWriteCommandDescriptor>(
        _ command: Command.Type,
        input: Command.Input,
        budget: DatabaseExecutionBudget = DatabaseExecutionBudget(),
        metadata: DatabaseRequestMetadata = DatabaseRequestMetadata()
    ) async throws(DatabaseClientError) -> DatabaseTypedWriteCommandResponse<Command.Output> {
        try await execute(
            DatabaseTypedWriteCommandOperation<Command>.self,
            request: DatabaseTypedCommandRequest<Command>(
                input: input,
                budget: budget
            ),
            metadata: metadata
        )
    }
}
