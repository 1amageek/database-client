import Testing
import Foundation
import Synchronization
import Core
import QueryIR
import DatabaseClientProtocol
@testable import DatabaseClient

// MARK: - Test Model

struct TestUser: Persistable, Codable, Sendable {
    typealias ID = String

    var id: String = UUID().uuidString
    var name: String = ""
    var age: Int = 0
    var active: Bool = true

    static var persistableType: String { "TestUser" }

    static var allFields: [String] { ["id", "name", "age", "active"] }

    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "id": return 1
        case "name": return 2
        case "age": return 3
        case "active": return 4
        default: return nil
        }
    }

    static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }

    subscript(dynamicMember member: String) -> (any Sendable)? {
        switch member {
        case "id": return id
        case "name": return name
        case "age": return age
        case "active": return active
        default: return nil
        }
    }

    static func fieldName<Value>(for keyPath: KeyPath<TestUser, Value>) -> String {
        if keyPath == \TestUser.id { return "id" }
        if keyPath == \TestUser.name { return "name" }
        if keyPath == \TestUser.age { return "age" }
        if keyPath == \TestUser.active { return "active" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: PartialKeyPath<TestUser>) -> String {
        if keyPath == \TestUser.id { return "id" }
        if keyPath == \TestUser.name { return "name" }
        if keyPath == \TestUser.age { return "age" }
        if keyPath == \TestUser.active { return "active" }
        return "\(keyPath)"
    }

    static func fieldName(for keyPath: AnyKeyPath) -> String {
        if let partialKeyPath = keyPath as? PartialKeyPath<TestUser> {
            return fieldName(for: partialKeyPath)
        }
        return "\(keyPath)"
    }
}

protocol TestDocument: Polymorphable {
    var id: String { get }
    var title: String { get }
}

extension TestDocument {
    static var polymorphableType: String { "TestDocument" }
    static var polymorphicDirectoryPathComponents: [any DirectoryPathElement] {
        [Path("test-documents")]
    }
}

struct TestArticle: Persistable, Codable, Sendable, TestDocument {
    typealias ID = String

    var id: String
    var title: String
    var body: String

    static var persistableType: String { "TestArticle" }
    static var allFields: [String] { ["id", "title", "body"] }
    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "id": return 1
        case "title": return 2
        case "body": return 3
        default: return nil
        }
    }
    static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }
    subscript(dynamicMember member: String) -> (any Sendable)? {
        switch member {
        case "id": return id
        case "title": return title
        case "body": return body
        default: return nil
        }
    }
}

struct TestReport: Persistable, Codable, Sendable, TestDocument {
    typealias ID = String

    var id: String
    var title: String
    var summary: String

    static var persistableType: String { "TestReport" }
    static var allFields: [String] { ["id", "title", "summary"] }
    static func fieldNumber(for fieldName: String) -> Int? {
        switch fieldName {
        case "id": return 1
        case "title": return 2
        case "summary": return 3
        default: return nil
        }
    }
    static func enumMetadata(for fieldName: String) -> EnumMetadata? { nil }
    subscript(dynamicMember member: String) -> (any Sendable)? {
        switch member {
        case "id": return id
        case "title": return title
        case "summary": return summary
        default: return nil
        }
    }
}

// MARK: - Thread-safe capture helper

final class Capture<T: Sendable>: Sendable {
    private let storage: Mutex<T?>
    init() { self.storage = Mutex(nil) }
    func set(_ value: T) { storage.withLock { $0 = value } }
    func get() -> T? { storage.withLock { $0 } }
}

final class Counter: Sendable {
    private let storage: Mutex<Int>
    init() { self.storage = Mutex(0) }
    func increment() -> Int { storage.withLock { $0 += 1; return $0 } }
    func get() -> Int { storage.withLock { $0 } }
}

final class Flag: Sendable {
    private let storage: Mutex<Bool>
    init() { self.storage = Mutex(false) }
    func set() { storage.withLock { $0 = true } }
    func get() -> Bool { storage.withLock { $0 } }
}

// MARK: - PredicateOperators Tests

@Suite("PredicateOperators")
struct PredicateOperatorsTests {

    @Test("== produces .equal expression")
    func equalOperator() {
        let expr: QueryIR.Expression = \TestUser.name == "Alice"
        guard case .equal(let lhs, let rhs) = expr else {
            Issue.record("Expected .equal, got \(expr)")
            return
        }
        guard case .column(let col) = lhs else {
            Issue.record("Expected .column on lhs")
            return
        }
        #expect(col.column == "name")
        guard case .literal(.string("Alice")) = rhs else {
            Issue.record("Expected .literal(.string(\"Alice\")), got \(rhs)")
            return
        }
    }

    @Test("!= produces .notEqual expression")
    func notEqualOperator() {
        let expr: QueryIR.Expression = \TestUser.name != "Admin"
        guard case .notEqual = expr else {
            Issue.record("Expected .notEqual")
            return
        }
    }

    @Test("> produces .greaterThan with correct column and literal")
    func greaterThanOperator() {
        let expr: QueryIR.Expression = \TestUser.age > 20
        guard case .greaterThan(let lhs, let rhs) = expr else {
            Issue.record("Expected .greaterThan")
            return
        }
        guard case .column(let col) = lhs else {
            Issue.record("Expected .column on lhs")
            return
        }
        #expect(col.column == "age")
        guard case .literal(.int(20)) = rhs else {
            Issue.record("Expected .literal(.int(20)), got \(rhs)")
            return
        }
    }

    @Test(">= produces .greaterThanOrEqual expression")
    func greaterThanOrEqualOperator() {
        let expr: QueryIR.Expression = \TestUser.age >= 18
        guard case .greaterThanOrEqual = expr else {
            Issue.record("Expected .greaterThanOrEqual")
            return
        }
    }

    @Test("< produces .lessThan expression")
    func lessThanOperator() {
        let expr: QueryIR.Expression = \TestUser.age < 10
        guard case .lessThan = expr else {
            Issue.record("Expected .lessThan")
            return
        }
    }

    @Test("<= produces .lessThanOrEqual expression")
    func lessThanOrEqualOperator() {
        let expr: QueryIR.Expression = \TestUser.age <= 65
        guard case .lessThanOrEqual = expr else {
            Issue.record("Expected .lessThanOrEqual")
            return
        }
    }

    @Test("&& produces .and expression")
    func andOperator() {
        let lhs: QueryIR.Expression = \TestUser.age > 20
        let rhs: QueryIR.Expression = \TestUser.name != "Admin"
        let expr = lhs && rhs
        guard case .and = expr else {
            Issue.record("Expected .and")
            return
        }
    }

    @Test("|| produces .or expression")
    func orOperator() {
        let lhs: QueryIR.Expression = \TestUser.age < 18
        let rhs: QueryIR.Expression = \TestUser.age > 65
        let expr = lhs || rhs
        guard case .or = expr else {
            Issue.record("Expected .or")
            return
        }
    }

    @Test("! produces .not expression")
    func notOperator() {
        let inner: QueryIR.Expression = \TestUser.active == true
        let expr = !inner
        guard case .not = expr else {
            Issue.record("Expected .not")
            return
        }
    }

    @Test("Bool field produces .literal(.bool)")
    func boolFieldComparison() {
        let expr: QueryIR.Expression = \TestUser.active == true
        guard case .equal(_, let rhs) = expr else {
            Issue.record("Expected .equal")
            return
        }
        guard case .literal(.bool(true)) = rhs else {
            Issue.record("Expected .literal(.bool(true)), got \(rhs)")
            return
        }
    }
}

// MARK: - Expression Codable Roundtrip Tests

@Suite("Expression Codable")
struct ExpressionCodableTests {

    @Test("Simple comparison roundtrip")
    func simpleComparisonRoundtrip() throws {
        let original: QueryIR.Expression = \TestUser.age > 20
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueryIR.Expression.self, from: data)
        #expect(original == decoded)
    }

    @Test("Compound predicate roundtrip")
    func compoundPredicateRoundtrip() throws {
        let a: QueryIR.Expression = \TestUser.age > 20
        let b: QueryIR.Expression = \TestUser.name == "Alice"
        let original = a && b
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueryIR.Expression.self, from: data)
        #expect(original == decoded)
    }

    @Test("SortKey roundtrip")
    func sortKeyRoundtrip() throws {
        let original = SortKey(
            .column(ColumnRef(column: "name")),
            direction: .ascending
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SortKey.self, from: data)
        #expect(original == decoded)
    }

    @Test("QueryRequest roundtrip")
    func queryRequestRoundtrip() throws {
        let original = QueryRequest(
            statement: .select(
                SelectQuery(
                    projection: .all,
                    source: .table(TableRef(table: "TestUser")),
                    filter: \TestUser.age > 20,
                    orderBy: [
                        SortKey(.column(ColumnRef(column: "name")), direction: .ascending)
                    ],
                    limit: 10
                )
            ),
            options: ReadExecutionOptions(
                consistency: .snapshot,
                pageSize: 25,
                continuation: QueryContinuation("next-page")
            ),
            partitionValues: ["tenantId": "t1"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueryRequest.self, from: data)
        guard case .select(let selectQuery) = decoded.statement else {
            Issue.record("Expected select statement")
            return
        }
        #expect(selectQuery.source == .table(TableRef(table: "TestUser")))
        #expect(selectQuery.filter == (\TestUser.age > 20))
        #expect(selectQuery.orderBy == [
            SortKey(.column(ColumnRef(column: "name")), direction: .ascending)
        ])
        #expect(selectQuery.limit == 10)
        #expect(decoded.options.consistency == .snapshot)
        #expect(decoded.options.pageSize == 25)
        #expect(decoded.options.continuation?.token == "next-page")
        #expect(decoded.partitionValues == ["tenantId": "t1"])
    }
}

// MARK: - QueryBuilder Tests

@Suite("QueryBuilder")
struct QueryBuilderTests {

    @Test("where combines predicates with AND")
    func whereCombinesWithAnd() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .where(\TestUser.age > 20)
            .where(\TestUser.name == "Alice")
            .execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        guard case .select(let selectQuery) = request.statement,
              let predicate = selectQuery.filter else {
            Issue.record("Expected select predicate")
            return
        }
        guard case .and(let lhs, let rhs) = predicate else {
            Issue.record("Expected .and predicate, got \(String(describing: predicate))")
            return
        }
        guard case .greaterThan = lhs else {
            Issue.record("Expected .greaterThan on lhs")
            return
        }
        guard case .equal = rhs else {
            Issue.record("Expected .equal on rhs")
            return
        }
    }

    @Test("sort adds SortKey with correct directions")
    func sortAddsSortKey() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .sort(by: \TestUser.name)
            .sort(by: \TestUser.age, ascending: false)
            .execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        guard case .select(let selectQuery) = request.statement,
              let sortDescriptors = selectQuery.orderBy else {
            Issue.record("Expected sort descriptors")
            return
        }
        #expect(sortDescriptors.count == 2)
        #expect(sortDescriptors[0].direction == .ascending)
        #expect(sortDescriptors[1].direction == .descending)
    }

    @Test("limit sets maximum results")
    func limitSetsMax() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self).limit(25).execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        guard case .select(let selectQuery) = request.statement else {
            Issue.record("Expected select statement")
            return
        }
        #expect(selectQuery.limit == 25)
    }

    @Test("partition sets partition values")
    func partitionSetsValues() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .partition(["tenantId": "t_123"])
            .execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        #expect(request.partitionValues == ["tenantId": "t_123"])
    }

    @Test("continuation sets token")
    func continuationSetsToken() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .continuation("abc123")
            .execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        #expect(request.options.continuation?.token == "abc123")
    }

    @Test("keysetPagination sends keyset seed token")
    func keysetPaginationSendsSeedToken() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .sort(by: \TestUser.age, ascending: false)
            .keysetPagination()
            .execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        #expect(request.options.continuation?.token == "keyset:v1")
    }

    @Test("consistency sets read consistency option")
    func consistencySetsOption() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .consistency(.snapshot)
            .execute()

        let request = try JSONDecoder().decode(QueryRequest.self, from: captured.get()!)
        #expect(request.options.consistency == .snapshot)
    }

    @Test("execute decodes response items and continuation")
    func executeDecodesItems() async throws {
        let transport = InProcessTransport { envelope in
            let rows: [QueryRow] = [
                QueryRow(fields: ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)]),
                QueryRow(fields: ["id": .string("u2"), "name": .string("Bob"), "age": .int64(25), "active": .bool(true)]),
            ]
            let response = QueryResponse(rows: rows, continuation: QueryContinuation("next-token"))
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let result = try await context.find(TestUser.self).execute()

        #expect(result.items.count == 2)
        #expect(result.items[0].name == "Alice")
        #expect(result.items[0].age == 30)
        #expect(result.items[1].name == "Bob")
        #expect(result.continuation == "next-token")
        #expect(result.hasMore == true)
    }

    @Test("first sets limit to 1 and returns single item")
    func firstReturnsSingle() async throws {
        let transport = InProcessTransport { envelope in
            let rows: [QueryRow] = [
                QueryRow(fields: ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)]),
            ]
            let response = QueryResponse(rows: rows)
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let user = try await context.find(TestUser.self).first()
        #expect(user?.name == "Alice")
    }

    @Test("cursor serializes concurrent next calls")
    func cursorSerializesConcurrentNextCalls() async throws {
        let requestTokens = Mutex<[String?]>([])

        let transport = InProcessTransport { envelope in
            let request = try JSONDecoder().decode(QueryRequest.self, from: envelope.payload)
            let token = request.options.continuation?.token
            requestTokens.withLock { $0.append(token) }
            try await Task.sleep(nanoseconds: 20_000_000)

            let response: QueryResponse
            if token == nil {
                response = QueryResponse(
                    rows: [
                        QueryRow(fields: ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)])
                    ],
                    continuation: QueryContinuation("page-2")
                )
            } else if token == "page-2" {
                response = QueryResponse(
                    rows: [
                        QueryRow(fields: ["id": .string("u2"), "name": .string("Bob"), "age": .int64(25), "active": .bool(true)])
                    ]
                )
            } else {
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: "query",
                    errorCode: "INVALID_CONTINUATION",
                    errorMessage: "Unexpected continuation token"
                )
            }

            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let cursor = context.find(TestUser.self).cursor(pageSize: 1)

        async let firstPage = cursor.next()
        async let secondPage = cursor.next()
        let (pageA, pageB) = try await (firstPage, secondPage)
        let pages = [pageA, pageB]

        #expect(pages.flatMap(\.items).map(\.id) == ["u1", "u2"])
        #expect(requestTokens.withLock { $0.map { $0 ?? "<nil>" } } == ["<nil>", "page-2"])
    }

    @Test("cancelled waiting cursor next does not consume a page")
    func cancelledWaitingCursorNextDoesNotConsumePage() async throws {
        let requestTokens = Mutex<[String?]>([])

        let transport = InProcessTransport { envelope in
            let request = try JSONDecoder().decode(QueryRequest.self, from: envelope.payload)
            let token = request.options.continuation?.token
            requestTokens.withLock { $0.append(token) }
            try await Task.sleep(nanoseconds: 50_000_000)

            let response: QueryResponse
            if token == nil {
                response = QueryResponse(
                    rows: [
                        QueryRow(fields: ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)])
                    ],
                    continuation: QueryContinuation("page-2")
                )
            } else if token == "page-2" {
                response = QueryResponse(
                    rows: [
                        QueryRow(fields: ["id": .string("u2"), "name": .string("Bob"), "age": .int64(25), "active": .bool(true)])
                    ]
                )
            } else {
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: "query",
                    errorCode: "INVALID_CONTINUATION",
                    errorMessage: "Unexpected continuation token"
                )
            }

            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let cursor = context.find(TestUser.self).cursor(pageSize: 1)

        let firstTask = Task { try await cursor.next() }
        while requestTokens.withLock({ $0.isEmpty }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let cancelledTask = Task { try await cursor.next() }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelledTask.cancel()

        do {
            _ = try await cancelledTask.value
            Issue.record("Expected waiting cursor task to be cancelled")
        } catch is CancellationError {
        }

        let firstPage = try await firstTask.value
        let secondPage = try await cursor.next()

        #expect(firstPage.items.map(\.id) == ["u1"])
        #expect(secondPage.items.map(\.id) == ["u2"])
        #expect(requestTokens.withLock { $0.map { $0 ?? "<nil>" } } == ["<nil>", "page-2"])
    }

    @Test("stream stops fetching when consumer terminates")
    func streamStopsFetchingWhenConsumerTerminates() async throws {
        let requestTokens = Mutex<[String?]>([])

        let transport = InProcessTransport { envelope in
            let request = try JSONDecoder().decode(QueryRequest.self, from: envelope.payload)
            let token = request.options.continuation?.token
            requestTokens.withLock { $0.append(token) }

            if token == nil {
                let response = QueryResponse(
                    rows: [
                        QueryRow(fields: ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)])
                    ],
                    continuation: QueryContinuation("page-2")
                )
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: "query",
                    payload: try JSONEncoder().encode(response)
                )
            }

            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                errorCode: "UNEXPECTED_PAGE_FETCH",
                errorMessage: "Stream fetched after consumer termination"
            )
        }

        let context = DatabaseContext(transport: transport)
        let cursor = context.find(TestUser.self).cursor(pageSize: 1)
        var receivedIDs: [String] = []

        for try await user in cursor.stream() {
            receivedIDs.append(user.id)
            break
        }

        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(receivedIDs == ["u1"])
        #expect(requestTokens.withLock { $0.map { $0 ?? "<nil>" } } == ["<nil>"])
    }

    @Test("count sends aggregate query")
    func countSendsAggregateQuery() async throws {
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "query")
            let request = try JSONDecoder().decode(QueryRequest.self, from: envelope.payload)
            guard case .select(let selectQuery) = request.statement else {
                Issue.record("Expected select statement")
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: "query",
                    errorCode: "INVALID",
                    errorMessage: "Expected select"
                )
            }
            #expect(selectQuery.projection == .items([
                ProjectionItem(.aggregate(.count(nil, distinct: false)), alias: "count")
            ]))
            let response = QueryResponse(rows: [QueryRow(fields: ["count": .int64(42)])])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let count = try await context.find(TestUser.self)
            .where(\TestUser.age >= 18)
            .count()

        #expect(count == 42)
    }

    @Test("error response throws ServiceError")
    func errorResponseThrows() async throws {
        let transport = InProcessTransport { envelope in
            ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                errorCode: "NOT_FOUND",
                errorMessage: "Entity not found"
            )
        }

        let context = DatabaseContext(transport: transport)
        do {
            _ = try await context.find(TestUser.self).execute()
            Issue.record("Expected error to be thrown")
        } catch let error as ServiceError {
            #expect(error.code == "NOT_FOUND")
            #expect(error.message == "Entity not found")
        }
    }
}

// MARK: - DatabaseContext Tests

@Suite("DatabaseContext")
struct DatabaseContextTests {

    @Test("save sends insert changes with correct fields")
    func saveInsertsChanges() async throws {
        let captured = Capture<SaveRequest>()

        let transport = InProcessTransport { envelope in
            if envelope.operationID == "save" {
                captured.set(try JSONDecoder().decode(SaveRequest.self, from: envelope.payload))
            }
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        try context.insert(TestUser(id: "u1", name: "Alice", age: 30, active: true))
        try await context.save()

        let request = captured.get()!
        #expect(request.changes.count == 1)
        let change = request.changes[0]
        #expect(change.entityName == "TestUser")
        #expect(change.id == "u1")
        #expect(change.operation == .insert)
        #expect(change.fields?["name"] == .string("Alice"))
        #expect(change.fields?["age"] == .int64(30))
    }

    @Test("save sends delete changes without fields")
    func saveDeleteChanges() async throws {
        let captured = Capture<SaveRequest>()

        let transport = InProcessTransport { envelope in
            if envelope.operationID == "save" {
                captured.set(try JSONDecoder().decode(SaveRequest.self, from: envelope.payload))
            }
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        context.delete(TestUser(id: "u1", name: "Alice", age: 30, active: true))
        try await context.save()

        let change = captured.get()!.changes[0]
        #expect(change.operation == .delete)
        #expect(change.fields == nil)
    }

    @Test("save batches multiple changes atomically")
    func saveBatchesChanges() async throws {
        let captured = Capture<SaveRequest>()

        let transport = InProcessTransport { envelope in
            if envelope.operationID == "save" {
                captured.set(try JSONDecoder().decode(SaveRequest.self, from: envelope.payload))
            }
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        try context.insert(TestUser(id: "u1", name: "Alice", age: 30))
        try context.insert(TestUser(id: "u2", name: "Bob", age: 25))
        context.delete(TestUser(id: "u3", name: "Carol", age: 40))
        try await context.save()

        let changes = captured.get()!.changes
        #expect(changes.count == 3)
        #expect(changes[0].operation == .insert)
        #expect(changes[1].operation == .insert)
        #expect(changes[2].operation == .delete)
    }

    @Test("save options sends write preconditions")
    func saveOptionsSendsPreconditions() async throws {
        let capturedEnvelope = Capture<ServiceEnvelope>()
        let captured = Capture<SaveRequest>()

        let transport = InProcessTransport { envelope in
            if envelope.operationID == "save" {
                capturedEnvelope.set(envelope)
                captured.set(try JSONDecoder().decode(SaveRequest.self, from: envelope.payload))
            }
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        try context.update(TestUser(id: "u1", name: "Alice", age: 31))
        try await context.save(options: SaveOptions(
            preconditions: [
                WritePreconditionEntry(
                    key: RecordKey(entityName: "TestUser", id: .string("u1")),
                    precondition: .matchesStored(RecordVersionToken("token-1"))
                )
            ],
            metadata: ["tenantID": "stamp"]
        ))

        let envelope = try #require(capturedEnvelope.get())
        let request = try #require(captured.get())
        #expect(envelope.metadata["tenantID"] == "stamp")
        #expect(request.preconditions.count == 1)
        #expect(request.preconditions[0].key.entityName == "TestUser")
        #expect(request.preconditions[0].precondition.kind == .matchesStored)
        #expect(request.preconditions[0].precondition.version?.value == "token-1")
    }

    @Test("save with no changes does not send request")
    func saveNoChanges() async throws {
        let flag = Flag()

        let transport = InProcessTransport { envelope in
            flag.set()
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        try await context.save()

        #expect(flag.get() == false)
    }

    @Test("clearChanges discards pending changes")
    func clearChangesDiscards() async throws {
        let flag = Flag()

        let transport = InProcessTransport { envelope in
            flag.set()
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        try context.insert(TestUser(id: "u1", name: "Alice", age: 30))
        context.clearChanges()
        try await context.save()

        #expect(flag.get() == false)
    }

    @Test("save restores changes on failure for retry")
    func saveRestoresOnFailure() async throws {
        let counter = Counter()

        let transport = InProcessTransport { envelope in
            let count = counter.increment()
            if count == 1 {
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: "save",
                    errorCode: "INTERNAL",
                    errorMessage: "Server error"
                )
            } else {
                return ServiceEnvelope(
                    responseTo: envelope.requestID,
                    operationID: "save"
                )
            }
        }

        let context = DatabaseContext(transport: transport)
        try context.insert(TestUser(id: "u1", name: "Alice", age: 30))

        do {
            try await context.save()
            Issue.record("Expected error")
        } catch {
            // expected
        }

        // Retry succeeds — changes were preserved
        try await context.save()
        #expect(counter.get() == 2)
    }

    @Test("save restores changes when transport throws")
    func saveRestoresChangesWhenTransportThrows() async throws {
        let counter = Counter()

        let transport = InProcessTransport { envelope in
            let count = counter.increment()
            if count == 1 {
                throw ServiceError(code: "TIMEOUT", message: "Request timed out")
            }
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID
            )
        }

        let context = DatabaseContext(transport: transport)
        try context.insert(TestUser(id: "transport-timeout-user", name: "Timeout", age: 1))

        do {
            try await context.save()
            Issue.record("Expected transport error")
        } catch let error as ServiceError {
            #expect(error.code == "TIMEOUT")
        }

        try await context.save()
        #expect(counter.get() == 2)
    }

    @Test("get decodes record by ID")
    func getDecodesRecord() async throws {
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "query")
            let record = QueryRow(fields: [
                "id": .string("u1"), "name": .string("Alice"),
                "age": .int64(30), "active": .bool(true)
            ])
            let response = QueryResponse(rows: [record])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let user = try await context.get(TestUser.self, id: "u1")

        #expect(user?.id == "u1")
        #expect(user?.name == "Alice")
        #expect(user?.age == 30)
    }

    @Test("get returns nil for missing record")
    func getReturnsNilWhenMissing() async throws {
        let transport = InProcessTransport { envelope in
            let response = QueryResponse(rows: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let user = try await context.get(TestUser.self, id: "nonexistent")
        #expect(user == nil)
    }

    @Test("fetchSchema sends schema operation")
    func fetchSchemaSendsSchemaOp() async throws {
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "schema")
            let response = SchemaResponse(entities: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "schema",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let entities = try await context.fetchSchema()
        #expect(entities.isEmpty)
    }

    @Test("fetchSchemaResponse preserves polymorphic groups")
    func fetchSchemaResponsePreservesPolymorphicGroups() async throws {
        let group = PolymorphicGroup(
            identifier: "TestDocument",
            directoryComponents: [.staticPath("test-documents")],
            memberTypeNames: ["TestArticle", "TestReport"]
        )
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "schema")
            let response = SchemaResponse(entities: [], polymorphicGroups: [group])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "schema",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let response = try await context.fetchSchemaResponse()
        #expect(response.polymorphicGroups == [group])
    }

    @Test("protocol-first query decodes mixed polymorphic results")
    func protocolFirstQueryDecodesMixedPolymorphicResults() async throws {
        let schema = Schema([TestArticle.self, TestReport.self])
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "query")
            let response = QueryResponse(
                rows: [
                    QueryRow(
                        fields: [
                            "id": .string("a1"),
                            "title": .string("Article"),
                            "body": .string("Body")
                        ],
                        annotations: ["_typeName": .string("TestArticle"), "_typeCode": .int64(TestArticle.typeCode(for: "TestArticle"))]
                    ),
                    QueryRow(
                        fields: [
                            "id": .string("r1"),
                            "title": .string("Report"),
                            "summary": .string("Summary")
                        ],
                        annotations: ["_typeName": .string("TestReport"), "_typeCode": .int64(TestReport.typeCode(for: "TestReport"))]
                    )
                ],
                continuation: QueryContinuation("next-page")
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "query",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport, localSchema: schema)
        let group = try #require(schema.polymorphicGroup(identifier: "TestDocument"))
        let page = try await context.findPolymorphic(group).executePage()

        #expect(page.items.count == 2)
        #expect(page.continuation == "next-page")
        #expect(page.items[0] is TestArticle)
        #expect(page.items[1] is TestReport)
    }
}

// MARK: - Extension Operation Tests

@Suite("Extension Operations")
struct ExtensionOperationTests {

    private struct ExtensionOperationRequest: Codable, Sendable, Equatable {
        var id: String
    }

    private struct ExtensionOperationResponse: Codable, Sendable, Equatable {
        var status: String
    }

    private struct TestCommandRequest: Codable, Sendable, Equatable {
        var id: String
    }

    private struct TestCommandResponse: Codable, Sendable, Equatable {
        var status: String
    }

    @Test("executeOperation sends typed payload and preserves metadata")
    func executeOperationSendsTypedPayloadAndMetadata() async throws {
        let capturedEnvelope = Capture<ServiceEnvelope>()

        let transport = InProcessTransport { envelope in
            capturedEnvelope.set(envelope)
            let response = ExtensionOperationResponse(status: "accepted")
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID,
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let response: ExtensionOperationResponse = try await context.executeOperation(
            "crm.command",
            request: ExtensionOperationRequest(id: "cmd-1"),
            metadata: ["tenantID": "stamp", "idempotencyKey": "idem-1"]
        )

        let envelope = try #require(capturedEnvelope.get())
        let decodedRequest = try JSONDecoder().decode(ExtensionOperationRequest.self, from: envelope.payload)
        #expect(envelope.operationID == "crm.command")
        #expect(envelope.metadata["tenantID"] == "stamp")
        #expect(envelope.metadata["idempotencyKey"] == "idem-1")
        #expect(decodedRequest == ExtensionOperationRequest(id: "cmd-1"))
        #expect(response == ExtensionOperationResponse(status: "accepted"))
    }

    @Test("executeCommand wraps command protocol and decodes command result")
    func executeCommandWrapsCommandProtocolAndDecodesCommandResult() async throws {
        let capturedEnvelope = Capture<ServiceEnvelope>()

        let transport = InProcessTransport { envelope in
            capturedEnvelope.set(envelope)
            let command = try JSONDecoder().decode(DatabaseClientProtocol.CommandRequest.self, from: envelope.payload)
            let decodedPayload = try JSONDecoder().decode(TestCommandRequest.self, from: command.payload)
            let responsePayload = try JSONEncoder().encode(TestCommandResponse(status: "accepted-\(decodedPayload.id)"))
            let commandResponse = DatabaseClientProtocol.CommandResponse(
                status: "applied",
                payload: responsePayload,
                effects: [
                    CommandEffect(
                        kind: "update",
                        key: RecordKey(entityName: "Ticket", id: .string(decodedPayload.id))
                    )
                ],
                replayed: true
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID,
                payload: try JSONEncoder().encode(commandResponse)
            )
        }

        let context = DatabaseContext(transport: transport)
        let result: ClientCommandResult<TestCommandResponse> = try await context.executeCommandResult(
            "ticket.resolve",
            request: TestCommandRequest(id: "ticket-1"),
            idempotencyKey: "resolve-1",
            preconditions: [
                WritePreconditionEntry(
                    key: RecordKey(entityName: "Ticket", id: .string("ticket-1")),
                    precondition: .exists
                )
            ],
            metadata: ["tenantID": "stamp"],
            envelopeMetadata: ["traceID": "trace-1"]
        )

        let envelope = try #require(capturedEnvelope.get())
        let command = try JSONDecoder().decode(DatabaseClientProtocol.CommandRequest.self, from: envelope.payload)
        let decodedRequest = try JSONDecoder().decode(TestCommandRequest.self, from: command.payload)

        #expect(envelope.operationID == "command")
        #expect(envelope.metadata["traceID"] == "trace-1")
        #expect(command.commandID == "ticket.resolve")
        #expect(command.idempotencyKey?.value == "resolve-1")
        #expect(command.metadata["tenantID"] == "stamp")
        #expect(command.preconditions.first?.precondition.kind == .exists)
        #expect(decodedRequest == TestCommandRequest(id: "ticket-1"))
        #expect(result.status == "applied")
        #expect(result.response == TestCommandResponse(status: "accepted-ticket-1"))
        #expect(result.effects.first?.kind == "update")
        #expect(result.replayed == true)
    }

    @Test("typed command descriptor wraps command protocol")
    func typedCommandDescriptorWrapsCommandProtocol() async throws {
        let capturedEnvelope = Capture<ServiceEnvelope>()

        let transport = InProcessTransport { envelope in
            capturedEnvelope.set(envelope)
            let command = try JSONDecoder().decode(DatabaseClientProtocol.CommandRequest.self, from: envelope.payload)
            let decodedPayload = try JSONDecoder().decode(TestCommandRequest.self, from: command.payload)
            let responsePayload = try JSONEncoder().encode(TestCommandResponse(status: decodedPayload.id))
            let commandResponse = DatabaseClientProtocol.CommandResponse(
                status: "applied",
                payload: responsePayload
            )
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: envelope.operationID,
                payload: try JSONEncoder().encode(commandResponse)
            )
        }

        let context = DatabaseContext(transport: transport)
        let command = TypedCommand<TestCommandRequest, TestCommandResponse>(
            "ticket.resolve",
            payload: TestCommandRequest(id: "ticket-2"),
            idempotencyKey: "resolve-2",
            metadata: ["tenantID": "stamp"],
            envelopeMetadata: ["traceID": "trace-2"]
        )
        let response: TestCommandResponse = try await context.execute(command)

        let envelope = try #require(capturedEnvelope.get())
        let request = try JSONDecoder().decode(DatabaseClientProtocol.CommandRequest.self, from: envelope.payload)
        #expect(envelope.operationID == "command")
        #expect(envelope.metadata["traceID"] == "trace-2")
        #expect(request.commandID == "ticket.resolve")
        #expect(request.idempotencyKey?.value == "resolve-2")
        #expect(request.metadata["tenantID"] == "stamp")
        #expect(response == TestCommandResponse(status: "ticket-2"))
    }
}

// MARK: - FieldValueDecoder Tests

@Suite("FieldValueDecoder")
struct FieldValueDecoderTests {

    @Test("encode and decode roundtrip preserves all fields")
    func encodeDecodeRoundtrip() throws {
        let original = TestUser(id: "u1", name: "Alice", age: 30, active: true)
        let dict = try FieldValueDecoder.encode(original)

        #expect(dict["id"] == .string("u1"))
        #expect(dict["name"] == .string("Alice"))
        #expect(dict["age"] == .int64(30))
        #expect(dict["active"] == .bool(true))

        let decoded: TestUser = try FieldValueDecoder.decode(dict)
        #expect(decoded.id == "u1")
        #expect(decoded.name == "Alice")
        #expect(decoded.age == 30)
        #expect(decoded.active == true)
    }

    @Test("integer one is not encoded as bool")
    func integerOneIsNotEncodedAsBool() throws {
        let original = TestUser(id: "u1", name: "Alice", age: 1, active: true)
        let dict = try FieldValueDecoder.encode(original)

        #expect(dict["age"] == .int64(1))
        #expect(dict["active"] == .bool(true))
    }

    @Test("idString extracts string ID")
    func idStringExtractsString() {
        let user = TestUser(id: "u1", name: "Alice", age: 30)
        #expect(FieldValueDecoder.idString(user) == "u1")
    }
}

// MARK: - ServiceEnvelope Tests

@Suite("ServiceEnvelope")
struct ServiceEnvelopeTests {

    @Test("request envelope has correct defaults")
    func requestEnvelopeDefaults() {
        let envelope = ServiceEnvelope(operationID: "query")
        #expect(envelope.operationID == "query")
        #expect(envelope.version == 1)
        #expect(envelope.isError == nil)
        #expect(envelope.errorCode == nil)
    }

    @Test("error envelope has error fields set")
    func errorEnvelopeFields() {
        let envelope = ServiceEnvelope(
            responseTo: "req-1",
            operationID: "query",
            errorCode: "NOT_FOUND",
            errorMessage: "Not found"
        )
        #expect(envelope.isError == true)
        #expect(envelope.errorCode == "NOT_FOUND")
        #expect(envelope.errorMessage == "Not found")
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let original = ServiceEnvelope(
            operationID: "save",
            payload: Data("test".utf8),
            metadata: ["auth": "token"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServiceEnvelope.self, from: data)
        #expect(decoded.operationID == "save")
        #expect(decoded.metadata == ["auth": "token"])
        #expect(decoded.payload == Data("test".utf8))
    }
}
