import Foundation
import Testing
import Core
import QueryIR
import DatabaseClientProtocol
@testable import DatabaseClient

private func databaseClientE2ESchema() -> Schema {
    Schema([
        TestUser.self,
        DatabaseClientE2EUser.self,
        TestArticle.self,
        TestReport.self,
    ])
}

@Suite("DatabaseClient E2E Tests")
struct DatabaseClientE2ETests {
    @Test("context saves, queries, fetches schema, and deletes through service envelopes")
    func contextSavesQueriesFetchesSchemaAndDeletesThroughServiceEnvelopes() async throws {
        let server = DatabaseClientE2EServer()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            }
        )

        let schema = try await context.fetchSchemaResponse()
        #expect(schema.entities.map(\.name).contains(TestUser.persistableType))

        try context.insert(TestUser(id: "database-client-e2e-alice", name: "Alice", age: 32, active: true))
        try context.insert(TestUser(id: "database-client-e2e-bob", name: "Bob", age: 24, active: false))
        try await context.save()

        let page = try await context.find(TestUser.self)
            .where(\TestUser.age >= 30)
            .limit(5)
            .execute()

        #expect(page.items.map(\TestUser.id) == ["database-client-e2e-alice"])
        #expect(page.items.first?.name == "Alice")

        let alice = try await context.get(TestUser.self, id: "database-client-e2e-alice")
        #expect(alice?.age == 32)

        context.delete(TestUser(id: "database-client-e2e-alice", name: "Alice", age: 32, active: true))
        try await context.save()

        let afterDelete = try await context.find(TestUser.self).execute()
        #expect(afterDelete.items.map(\.id) == ["database-client-e2e-bob"])
    }

    @Test("context executes partitioned sorted pagination, annotations, and aggregate count")
    func contextExecutesPartitionedSortedPaginationAnnotationsAndAggregateCount() async throws {
        let server = DatabaseClientE2EServer()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            }
        )

        try context.insert(DatabaseClientE2EUser(
            id: "tenant-a-alice",
            tenantID: "tenant-a",
            name: "Alice",
            age: 36,
            active: true
        ))
        try context.insert(DatabaseClientE2EUser(
            id: "tenant-a-bob",
            tenantID: "tenant-a",
            name: "Bob",
            age: 28,
            active: true
        ))
        try context.insert(DatabaseClientE2EUser(
            id: "tenant-a-cara",
            tenantID: "tenant-a",
            name: "Cara",
            age: 41,
            active: true
        ))
        try context.insert(DatabaseClientE2EUser(
            id: "tenant-a-dan",
            tenantID: "tenant-a",
            name: "Dan",
            age: 22,
            active: true
        ))
        try context.insert(DatabaseClientE2EUser(
            id: "tenant-b-eve",
            tenantID: "tenant-b",
            name: "Eve",
            age: 50,
            active: true
        ))
        try await context.save()

        let firstPage = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-a"])
            .where(\DatabaseClientE2EUser.active == true)
            .where(\DatabaseClientE2EUser.age >= 25)
            .sort(by: \DatabaseClientE2EUser.age, ascending: false)
            .pageSize(2)
            .executeAnnotated()

        #expect(firstPage.items.map(\.id) == ["tenant-a-cara", "tenant-a-alice"])
        #expect(firstPage.continuation == "2")
        #expect(firstPage.hasMore == true)
        #expect(firstPage.metadata["source"] == .string("database-client-e2e"))
        #expect(firstPage.metadata["matchedRows"] == .int64(3))
        #expect(firstPage.records.compactMap { $0.annotations["rank"] } == [.int64(1), .int64(2)])

        let secondPage = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-a"])
            .where(\DatabaseClientE2EUser.active == true)
            .where(\DatabaseClientE2EUser.age >= 25)
            .sort(by: \DatabaseClientE2EUser.age, ascending: false)
            .pageSize(2)
            .continuation(try #require(firstPage.continuation))
            .execute()

        #expect(secondPage.items.map(\.id) == ["tenant-a-bob"])
        #expect(secondPage.hasMore == false)

        let matchedCount = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-a"])
            .where(\DatabaseClientE2EUser.active == true)
            .where(\DatabaseClientE2EUser.age >= 25)
            .count()
        #expect(matchedCount == 3)

        let bob = try await context.get(
            DatabaseClientE2EUser.self,
            id: "tenant-a-bob",
            partitionValues: ["tenantID": "tenant-a"]
        )
        #expect(bob?.name == "Bob")

        context.delete(DatabaseClientE2EUser(
            id: "tenant-a-bob",
            tenantID: "tenant-a",
            name: "Bob",
            age: 28,
            active: true
        ))
        try await context.save()

        let afterDeleteCount = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-a"])
            .where(\DatabaseClientE2EUser.active == true)
            .where(\DatabaseClientE2EUser.age >= 25)
            .count()
        #expect(afterDeleteCount == 2)
    }

    @Test("cursor and stream drain multi-page query results without duplicates")
    func cursorAndStreamDrainMultiPageQueryResultsWithoutDuplicates() async throws {
        let server = DatabaseClientE2EServer()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            }
        )

        for index in 1...5 {
            try context.insert(DatabaseClientE2EUser(
                id: "cursor-user-\(index)",
                tenantID: "cursor-tenant",
                name: "Cursor User \(index)",
                age: 20 + index,
                active: true
            ))
        }
        try await context.save()

        let cursor = context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "cursor-tenant"])
            .sort(by: \DatabaseClientE2EUser.age)
            .cursor(pageSize: 2)

        let firstPage = try await cursor.next()
        let secondPage = try await cursor.next()
        let thirdPage = try await cursor.next()
        let exhaustedPage = try await cursor.next()

        #expect(firstPage.items.map(\.id) == ["cursor-user-1", "cursor-user-2"])
        #expect(firstPage.hasMore == true)
        #expect(secondPage.items.map(\.id) == ["cursor-user-3", "cursor-user-4"])
        #expect(secondPage.hasMore == true)
        #expect(thirdPage.items.map(\.id) == ["cursor-user-5"])
        #expect(thirdPage.hasMore == false)
        #expect(exhaustedPage.items.isEmpty)

        var streamedIDs: [String] = []
        for try await user in context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "cursor-tenant"])
            .sort(by: \DatabaseClientE2EUser.age)
            .stream(pageSize: 2) {
            streamedIDs.append(user.id)
        }

        #expect(streamedIDs == [
            "cursor-user-1",
            "cursor-user-2",
            "cursor-user-3",
            "cursor-user-4",
            "cursor-user-5",
        ])
        #expect(Set(streamedIDs).count == streamedIDs.count)
    }

    @Test("save failure restores pending changes for retry")
    func saveFailureRestoresPendingChangesForRetry() async throws {
        let server = DatabaseClientE2EServer(saveFailures: 1)
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            }
        )

        try context.insert(TestUser(
            id: "database-client-retry-alice",
            name: "Retry Alice",
            age: 34,
            active: true
        ))

        do {
            try await context.save()
            Issue.record("Expected first save to fail")
        } catch let error as ServiceError {
            #expect(error.code == "SAVE_REJECTED")
        }

        let beforeRetry = try await context.find(TestUser.self)
            .where(\TestUser.id == "database-client-retry-alice")
            .execute()
        #expect(beforeRetry.items.isEmpty)

        try await context.save()

        let afterRetry = try await context.find(TestUser.self)
            .where(\TestUser.id == "database-client-retry-alice")
            .execute()
        #expect(afterRetry.items.map(\.name) == ["Retry Alice"])
    }

    @Test("mixed change set failure restores updates deletes inserts and retries as one workflow")
    func mixedChangeSetFailureRestoresUpdatesDeletesInsertsAndRetriesAsOneWorkflow() async throws {
        let server = DatabaseClientE2EServer(saveFailures: 1)
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            }
        )

        try context.insert(DatabaseClientE2EUser(
            id: "mixed-update",
            tenantID: "tenant-mixed",
            name: "Before Update",
            age: 31,
            active: true
        ))
        try context.insert(DatabaseClientE2EUser(
            id: "mixed-delete",
            tenantID: "tenant-mixed",
            name: "Before Delete",
            age: 32,
            active: true
        ))
        do {
            try await context.save()
            Issue.record("Expected initial save to fail")
        } catch let error as ServiceError {
            #expect(error.code == "SAVE_REJECTED")
        }
        try await context.save()

        try context.update(DatabaseClientE2EUser(
            id: "mixed-update",
            tenantID: "tenant-mixed",
            name: "After Update",
            age: 41,
            active: true
        ))
        context.delete(DatabaseClientE2EUser(
            id: "mixed-delete",
            tenantID: "tenant-mixed",
            name: "Before Delete",
            age: 32,
            active: true
        ))
        try context.insert(DatabaseClientE2EUser(
            id: "mixed-insert",
            tenantID: "tenant-mixed",
            name: "Inserted",
            age: 35,
            active: true
        ))
        try await context.save()

        let page = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-mixed"])
            .where(\DatabaseClientE2EUser.active == true)
            .sort(by: \DatabaseClientE2EUser.age)
            .pageSize(1)
            .executeAnnotated()

        #expect(page.items.map(\.id) == ["mixed-insert"])
        #expect(page.continuation == "1")
        #expect(page.metadata["matchedRows"] == .int64(2))
        #expect(page.records.first?.annotations["tenantID"] == .string("tenant-mixed"))

        let secondPage = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-mixed"])
            .where(\DatabaseClientE2EUser.active == true)
            .sort(by: \DatabaseClientE2EUser.age)
            .pageSize(1)
            .continuation(try #require(page.continuation))
            .execute()

        #expect(secondPage.items.map(\.id) == ["mixed-update"])
        #expect(secondPage.items.first?.name == "After Update")
        #expect(secondPage.hasMore == false)

        let deleted = try await context.get(
            DatabaseClientE2EUser.self,
            id: "mixed-delete",
            partitionValues: ["tenantID": "tenant-mixed"]
        )
        #expect(deleted == nil)

        let count = try await context.find(DatabaseClientE2EUser.self)
            .partition(["tenantID": "tenant-mixed"])
            .count()
        #expect(count == 2)
    }

    @Test("query decode failures surface typed errors instead of being swallowed")
    func queryDecodeFailuresSurfaceTypedErrorsInsteadOfBeingSwallowed() async throws {
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                #expect(envelope.operationID == "query")
                let response = QueryResponse(rows: [
                    QueryRow(fields: [
                        "id": .string("database-client-bad-row"),
                        "name": .string("Broken User"),
                        "age": .string("not-an-int"),
                        "active": .bool(true),
                    ])
                ])
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    payload: try JSONEncoder().encode(response)
                )
            }
        )

        do {
            _ = try await context.find(TestUser.self).execute()
            Issue.record("Expected decode failure")
        } catch let error as DecodingError {
            switch error {
            case .typeMismatch(let type, _):
                #expect(String(describing: type) == "Int")
            case .dataCorrupted, .keyNotFound, .valueNotFound:
                break
            @unknown default:
                Issue.record("Unexpected decoding error: \(error)")
            }
        }
    }

    @Test("query errors preserve server error code and message")
    func queryErrorsPreserveServerErrorCodeAndMessage() async throws {
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                #expect(envelope.operationID == "query")
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    errorCode: "QUERY_REJECTED",
                    errorMessage: "Simulated query rejection"
                )
            }
        )

        do {
            _ = try await context.find(TestUser.self)
                .where(\TestUser.age >= 18)
                .execute()
            Issue.record("Expected query to fail")
        } catch let error as ServiceError {
            #expect(error.code == "QUERY_REJECTED")
            #expect(error.message == "Simulated query rejection")
        }
    }

    @Test("schema decode failures surface decoding errors")
    func schemaDecodeFailuresSurfaceDecodingErrors() async throws {
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                #expect(envelope.operationID == "schema")
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    payload: Data("{\"entities\":\"not-an-array\"}".utf8)
                )
            }
        )

        do {
            _ = try await context.fetchSchemaResponse()
            Issue.record("Expected schema decode failure")
        } catch let error as DecodingError {
            switch error {
            case .typeMismatch, .dataCorrupted, .keyNotFound, .valueNotFound:
                break
            @unknown default:
                Issue.record("Unexpected decoding error: \(error)")
            }
        }
    }

    @Test("unconnected WebSocket transport surfaces not connected error")
    func unconnectedWebSocketTransportSurfacesNotConnectedError() async throws {
        let context = DatabaseContext(
            transport: WebSocketTransport(url: URL(string: "ws://localhost:1/database-client-e2e")!)
        )

        do {
            _ = try await context.find(TestUser.self).execute()
            Issue.record("Expected unconnected WebSocket transport to fail")
        } catch let error as ServiceError {
            #expect(error.code == "NOT_CONNECTED")
            #expect(error.message == "WebSocket is not connected")
        }
    }

    @Test("disconnect resumes pending transport requests with disconnected error")
    func disconnectResumesPendingTransportRequestsWithDisconnectedError() async throws {
        let transport = DatabaseClientE2EPendingTransport()
        let context = DatabaseContext(transport: transport)

        let queryTask = Task {
            try await context.find(TestUser.self).execute()
        }

        await transport.waitForPendingSend()
        await context.disconnect()

        do {
            _ = try await queryTask.value
            Issue.record("Expected pending request to fail when disconnected")
        } catch let error as ServiceError {
            #expect(error.code == "DISCONNECTED")
            #expect(error.message == "Connection closed")
        }
    }

    @Test("context fetches polymorphic schema and decodes mixed polymorphic query results")
    func contextFetchesPolymorphicSchemaAndDecodesMixedPolymorphicQueryResults() async throws {
        let server = DatabaseClientE2EServer()
        let schema = databaseClientE2ESchema()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            },
            localSchema: schema
        )

        let fetchedSchema = try await context.fetchSchemaResponse()
        let group = try #require(fetchedSchema.polymorphicGroups.first {
            $0.identifier == TestArticle.polymorphableType
        })

        try context.insert(TestArticle(id: "database-client-article", title: "Article", body: "Body"))
        try context.insert(TestReport(id: "database-client-report", title: "Report", summary: "Summary"))
        try await context.save()

        let page = try await context.findPolymorphic(group).executePage()

        #expect(page.continuation == nil)
        #expect(page.items.count == 2)
        #expect(page.items[0] is TestArticle)
        #expect(page.items[1] is TestReport)
    }

    @Test("polymorphic query without local schema surfaces schema required error")
    func polymorphicQueryWithoutLocalSchemaSurfacesSchemaRequiredError() async throws {
        let server = DatabaseClientE2EServer()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                try await server.handle(envelope)
            }
        )

        try context.insert(TestArticle(id: "database-client-schema-required-article", title: "Article", body: "Body"))
        try await context.save()

        do {
            _ = try await context.findPolymorphic(TestArticle.polymorphableType).executePage()
            Issue.record("Expected polymorphic decode to require local schema")
        } catch let error as ServiceError {
            #expect(error.code == "SCHEMA_REQUIRED")
        }
    }

    @Test("polymorphic query missing type annotation surfaces invalid response")
    func polymorphicQueryMissingTypeAnnotationSurfacesInvalidResponse() async throws {
        let schema = databaseClientE2ESchema()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                #expect(envelope.operationID == "query")
                let response = QueryResponse(rows: [
                    QueryRow(fields: [
                        "id": .string("database-client-missing-type"),
                        "title": .string("Untyped Article"),
                        "body": .string("Body"),
                    ])
                ])
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    payload: try JSONEncoder().encode(response)
                )
            },
            localSchema: schema
        )

        do {
            _ = try await context.findPolymorphic(TestArticle.polymorphableType).executePage()
            Issue.record("Expected missing _typeName annotation to fail")
        } catch let error as ServiceError {
            #expect(error.code == "INVALID_RESPONSE")
        }
    }

    @Test("polymorphic query for unknown local group preserves typed error")
    func polymorphicQueryForUnknownLocalGroupPreservesTypedError() async throws {
        let schema = databaseClientE2ESchema()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                #expect(envelope.operationID == "query")
                let response = QueryResponse(rows: [
                    QueryRow(
                        fields: [
                            "id": .string("database-client-unknown-group"),
                            "title": .string("Unknown Group Article"),
                            "body": .string("Body"),
                        ],
                        annotations: ["_typeName": .string(TestArticle.persistableType)]
                    )
                ])
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    payload: try JSONEncoder().encode(response)
                )
            },
            localSchema: schema
        )

        do {
            _ = try await context.findPolymorphic("MissingDocumentGroup").executePage()
            Issue.record("Expected unknown local polymorphic group to fail")
        } catch let error as ServiceError {
            #expect(error.code == "UNKNOWN_POLYMORPHIC_GROUP")
        }
    }

    @Test("polymorphic query for unknown concrete type preserves typed error")
    func polymorphicQueryForUnknownConcreteTypePreservesTypedError() async throws {
        let schema = databaseClientE2ESchema()
        let context = DatabaseContext(
            transport: InProcessTransport { envelope in
                #expect(envelope.operationID == "query")
                let response = QueryResponse(rows: [
                    QueryRow(
                        fields: [
                            "id": .string("database-client-unknown-type"),
                            "title": .string("Unknown Type Article"),
                            "body": .string("Body"),
                        ],
                        annotations: ["_typeName": .string("DatabaseClientUnknownDocument")]
                    )
                ])
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    payload: try JSONEncoder().encode(response)
                )
            },
            localSchema: schema
        )

        do {
            _ = try await context.findPolymorphic(TestArticle.polymorphableType).executePage()
            Issue.record("Expected unknown concrete polymorphic type to fail")
        } catch let error as ServiceError {
            #expect(error.code == "UNKNOWN_PERSISTABLE_TYPE")
        }
    }
}

private actor DatabaseClientE2EPendingTransport: DatabaseTransport {
    private var pendingContinuation: CheckedContinuation<ServiceEnvelope, any Error>?
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope {
        try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            let waiters = pendingWaiters
            pendingWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func disconnect() async {
        guard let pendingContinuation else {
            return
        }
        self.pendingContinuation = nil
        pendingContinuation.resume(
            throwing: ServiceError(code: "DISCONNECTED", message: "Connection closed")
        )
    }

    func waitForPendingSend() async {
        if pendingContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            pendingWaiters.append(continuation)
        }
    }
}

private actor DatabaseClientE2EServer {
    private struct StoredRow: Sendable {
        var entityName: String
        var fields: [String: FieldValue]
    }

    private var rows: [String: StoredRow] = [:]
    private var remainingSaveFailures: Int

    init(saveFailures: Int = 0) {
        self.remainingSaveFailures = saveFailures
    }

    func handle(_ envelope: ServiceEnvelope) async throws -> ServiceEnvelope {
        switch envelope.operationID {
        case "schema":
            let schema = databaseClientE2ESchema()
            let response = SchemaResponse(
                entities: schema.entities,
                polymorphicGroups: schema.polymorphicGroups
            )
            return try successResponse(to: envelope, payload: response)
        case "save":
            if remainingSaveFailures > 0 {
                remainingSaveFailures -= 1
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: envelope.operationID,
                    errorCode: "SAVE_REJECTED",
                    errorMessage: "Simulated save failure"
                )
            }
            let request = try JSONDecoder().decode(SaveRequest.self, from: envelope.payload)
            for change in request.changes {
                let key = rowKey(entityName: change.entityName, id: change.id)
                switch change.operation {
                case .insert, .update:
                    rows[key] = StoredRow(entityName: change.entityName, fields: change.fields ?? [:])
                case .delete:
                    rows.removeValue(forKey: key)
                }
            }
            return ServiceEnvelope(responseTo: envelope.requestID, operationID: envelope.operationID)
        case "query":
            let request = try JSONDecoder().decode(QueryRequest.self, from: envelope.payload)
            let response = try responseForQuery(request)
            return try successResponse(to: envelope, payload: response)
        default:
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID,
                errorCode: "UNKNOWN_OPERATION",
                errorMessage: envelope.operationID
            )
        }
    }

    private func successResponse<T: Encodable>(
        to envelope: ServiceEnvelope,
        payload: T
    ) throws -> ServiceEnvelope {
        ServiceEnvelope(
            responseTo: envelope.requestID,
            operationID: envelope.operationID,
            payload: try JSONEncoder().encode(payload)
        )
    }

    private func responseForQuery(_ request: QueryRequest) throws -> QueryResponse {
        guard case .select(let select) = request.statement else {
            return QueryResponse(rows: [])
        }

        let schema = databaseClientE2ESchema()
        let entityName = tableName(for: select.source)
        let logicalGroupIdentifier = polymorphicGroupIdentifier(for: select.source)
        var matchingRows = rows.values.filter { row in
            if let entityName, row.entityName != entityName {
                return false
            }
            if let logicalGroupIdentifier {
                guard let group = schema.polymorphicGroup(identifier: logicalGroupIdentifier),
                      group.memberTypeNames.contains(row.entityName) else {
                    return false
                }
            }
            if let partitionValues = request.partitionValues {
                for (fieldName, expected) in partitionValues {
                    guard row.fields[fieldName] == .string(expected) else {
                        return false
                    }
                }
            }
            guard let filter = select.filter else {
                return true
            }
            return evaluate(filter, fields: row.fields)
        }

        if let orderBy = select.orderBy {
            matchingRows.sort { lhs, rhs in
                for key in orderBy {
                    let lhsValue = value(for: key.expression, fields: lhs.fields)
                    let rhsValue = value(for: key.expression, fields: rhs.fields)
                    if lhsValue == rhsValue {
                        continue
                    }
                    let ascending = compare(lhsValue, rhsValue) == .orderedAscending
                    return key.direction == .ascending ? ascending : !ascending
                }
                return false
            }
        } else {
            matchingRows.sort {
                ($0.fields["id"]?.stringValue ?? "") < ($1.fields["id"]?.stringValue ?? "")
            }
        }

        if isCountProjection(select.projection) {
            return QueryResponse(
                rows: [QueryRow(fields: ["count": .int64(Int64(matchingRows.count))])],
                metadata: ["source": .string("database-client-e2e")]
            )
        }

        if let offset = select.offset, offset > 0 {
            matchingRows = Array(matchingRows.dropFirst(offset))
        }
        if let limit = select.limit {
            matchingRows = Array(matchingRows.prefix(limit))
        }

        let pageOffset: Int
        if let token = request.options.continuation?.token, let offset = Int(token) {
            pageOffset = offset
        } else {
            pageOffset = 0
        }
        let pageSize = request.options.pageSize ?? matchingRows.count
        let pageRows = Array(matchingRows.dropFirst(pageOffset).prefix(pageSize))
        let nextOffset = pageOffset + pageRows.count
        let continuation = nextOffset < matchingRows.count ? QueryContinuation("\(nextOffset)") : nil
        var responseRows: [QueryRow] = []
        for (index, row) in pageRows.enumerated() {
            var annotations: [String: FieldValue] = [
                "rank": .int64(Int64(pageOffset + index + 1)),
                "tenantID": row.fields["tenantID"] ?? .null,
                "_typeName": .string(row.entityName),
            ]
            if let type = schema.entity(named: row.entityName)?.persistableType as? any Polymorphable.Type {
                annotations["_typeCode"] = .int64(type.typeCode(for: row.entityName))
            }
            responseRows.append(QueryRow(
                fields: row.fields,
                annotations: annotations
            ))
        }
        let metadata: [String: FieldValue] = [
            "source": .string("database-client-e2e"),
            "matchedRows": .int64(Int64(matchingRows.count)),
        ]

        return QueryResponse(
            rows: responseRows,
            continuation: continuation,
            metadata: metadata
        )
    }

    private func rowKey(entityName: String, id: String) -> String {
        "\(entityName):\(id)"
    }

    private func tableName(for source: DataSource) -> String? {
        guard case .table(let table) = source else {
            return nil
        }
        return table.table
    }

    private func polymorphicGroupIdentifier(for source: DataSource) -> String? {
        guard case .logical(let logicalSource) = source,
              logicalSource.kindIdentifier == BuiltinLogicalSourceKind.polymorphic else {
            return nil
        }
        return logicalSource.identifier
    }

    private func isCountProjection(_ projection: Projection) -> Bool {
        guard case .items(let items) = projection,
              items.count == 1,
              case .aggregate(.count(nil, distinct: false)) = items[0].expression else {
            return false
        }
        return true
    }

    private func evaluate(_ expression: QueryIR.Expression, fields: [String: FieldValue]) -> Bool {
        switch expression {
        case .and(let lhs, let rhs):
            evaluate(lhs, fields: fields) && evaluate(rhs, fields: fields)
        case .greaterThanOrEqual(let lhs, let rhs):
            compare(value(for: lhs, fields: fields), value(for: rhs, fields: fields)) != .orderedAscending
        case .greaterThan(let lhs, let rhs):
            compare(value(for: lhs, fields: fields), value(for: rhs, fields: fields)) == .orderedDescending
        case .lessThanOrEqual(let lhs, let rhs):
            compare(value(for: lhs, fields: fields), value(for: rhs, fields: fields)) != .orderedDescending
        case .lessThan(let lhs, let rhs):
            compare(value(for: lhs, fields: fields), value(for: rhs, fields: fields)) == .orderedAscending
        case .equal(let lhs, let rhs):
            value(for: lhs, fields: fields) == value(for: rhs, fields: fields)
        default:
            true
        }
    }

    private func value(for expression: QueryIR.Expression, fields: [String: FieldValue]) -> FieldValue {
        switch expression {
        case .column(let column):
            fields[column.column] ?? .null
        case .literal(let literal):
            value(for: literal)
        default:
            .null
        }
    }

    private func value(for literal: Literal) -> FieldValue {
        switch literal {
        case .int(let value):
            .int64(Int64(value))
        case .string(let value):
            .string(value)
        case .bool(let value):
            .bool(value)
        case .double(let value):
            .double(value)
        case .null:
            .null
        default:
            .null
        }
    }

    private func compare(_ lhs: FieldValue, _ rhs: FieldValue) -> ComparisonResult {
        if let lhs = lhs.stringValue, let rhs = rhs.stringValue {
            return lhs.compare(rhs)
        }
        if let lhs = lhs.asDouble, let rhs = rhs.asDouble {
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }
}

private struct DatabaseClientE2EUser: Persistable, Codable, Sendable {
    typealias ID = String

    var id: String
    var tenantID: String
    var name: String
    var age: Int
    var active: Bool

    static var persistableType: String { "DatabaseClientE2EUser" }
    static var allFields: [String] { ["id", "tenantID", "name", "age", "active"] }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "id": return 1
        case "tenantID": return 2
        case "name": return 3
        case "age": return 4
        case "active": return 5
        default: return nil
        }
    }

    static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

    subscript(dynamicMember member: String) -> (any Sendable)? {
        switch member {
        case "id": return id
        case "tenantID": return tenantID
        case "name": return name
        case "age": return age
        case "active": return active
        default: return nil
        }
    }

    static func fieldName<Value>(for keyPath: KeyPath<DatabaseClientE2EUser, Value>) -> String {
        if keyPath == \DatabaseClientE2EUser.id { return "id" }
        if keyPath == \DatabaseClientE2EUser.tenantID { return "tenantID" }
        if keyPath == \DatabaseClientE2EUser.name { return "name" }
        if keyPath == \DatabaseClientE2EUser.age { return "age" }
        if keyPath == \DatabaseClientE2EUser.active { return "active" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: PartialKeyPath<DatabaseClientE2EUser>) -> String {
        if keyPath == \DatabaseClientE2EUser.id { return "id" }
        if keyPath == \DatabaseClientE2EUser.tenantID { return "tenantID" }
        if keyPath == \DatabaseClientE2EUser.name { return "name" }
        if keyPath == \DatabaseClientE2EUser.age { return "age" }
        if keyPath == \DatabaseClientE2EUser.active { return "active" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: AnyKeyPath) -> String {
        if let partialKeyPath = keyPath as? PartialKeyPath<DatabaseClientE2EUser> {
            return fieldName(for: partialKeyPath)
        }
        return "\(keyPath)"
    }
}
