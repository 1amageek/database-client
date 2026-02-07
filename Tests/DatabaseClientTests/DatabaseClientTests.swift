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

    @Test("FetchRequest roundtrip")
    func fetchRequestRoundtrip() throws {
        let original = FetchRequest(
            entityName: "TestUser",
            predicate: \TestUser.age > 20,
            sortDescriptors: [
                SortKey(.column(ColumnRef(column: "name")), direction: .ascending)
            ],
            limit: 10,
            partitionValues: ["tenantId": "t1"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FetchRequest.self, from: data)
        #expect(decoded.entityName == "TestUser")
        #expect(decoded.predicate == original.predicate)
        #expect(decoded.sortDescriptors == original.sortDescriptors)
        #expect(decoded.limit == 10)
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
            let response = FetchResponse(records: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .where(\TestUser.age > 20)
            .where(\TestUser.name == "Alice")
            .execute()

        let request = try JSONDecoder().decode(FetchRequest.self, from: captured.get()!)
        guard case .and(let lhs, let rhs) = request.predicate else {
            Issue.record("Expected .and predicate, got \(String(describing: request.predicate))")
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
            let response = FetchResponse(records: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .sort(by: \TestUser.name)
            .sort(by: \TestUser.age, ascending: false)
            .execute()

        let request = try JSONDecoder().decode(FetchRequest.self, from: captured.get()!)
        #expect(request.sortDescriptors.count == 2)
        #expect(request.sortDescriptors[0].direction == .ascending)
        #expect(request.sortDescriptors[1].direction == .descending)
    }

    @Test("limit sets maximum results")
    func limitSetsMax() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = FetchResponse(records: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self).limit(25).execute()

        let request = try JSONDecoder().decode(FetchRequest.self, from: captured.get()!)
        #expect(request.limit == 25)
    }

    @Test("partition sets partition values")
    func partitionSetsValues() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = FetchResponse(records: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .partition(["tenantId": "t_123"])
            .execute()

        let request = try JSONDecoder().decode(FetchRequest.self, from: captured.get()!)
        #expect(request.partitionValues == ["tenantId": "t_123"])
    }

    @Test("continuation sets token")
    func continuationSetsToken() async throws {
        let captured = Capture<Data>()

        let transport = InProcessTransport { envelope in
            captured.set(envelope.payload)
            let response = FetchResponse(records: [])
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        _ = try await context.find(TestUser.self)
            .continuation("abc123")
            .execute()

        let request = try JSONDecoder().decode(FetchRequest.self, from: captured.get()!)
        #expect(request.continuation == "abc123")
    }

    @Test("execute decodes response items and continuation")
    func executeDecodesItems() async throws {
        let transport = InProcessTransport { envelope in
            let records: [[String: FieldValue]] = [
                ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)],
                ["id": .string("u2"), "name": .string("Bob"), "age": .int64(25), "active": .bool(true)],
            ]
            let response = FetchResponse(records: records, continuation: "next-token")
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
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
            let records: [[String: FieldValue]] = [
                ["id": .string("u1"), "name": .string("Alice"), "age": .int64(30), "active": .bool(true)],
            ]
            let response = FetchResponse(records: records)
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "fetch",
                payload: try JSONEncoder().encode(response)
            )
        }

        let context = DatabaseContext(transport: transport)
        let user = try await context.find(TestUser.self).first()
        #expect(user?.name == "Alice")
    }

    @Test("count sends count operation")
    func countSendsCountOp() async throws {
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "count")
            let response = CountResponse(count: 42)
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "count",
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
                operationID: "fetch",
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

    @Test("get decodes record by ID")
    func getDecodesRecord() async throws {
        let transport = InProcessTransport { envelope in
            #expect(envelope.operationID == "get")
            let record: [String: FieldValue] = [
                "id": .string("u1"), "name": .string("Alice"),
                "age": .int64(30), "active": .bool(true)
            ]
            let response = GetResponse(record: record)
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "get",
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
            let response = GetResponse(record: nil)
            return ServiceEnvelope(
                responseTo: envelope.requestID,
                operationID: "get",
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
        let envelope = ServiceEnvelope(operationID: "fetch")
        #expect(envelope.operationID == "fetch")
        #expect(envelope.version == 1)
        #expect(envelope.isError == nil)
        #expect(envelope.errorCode == nil)
    }

    @Test("error envelope has error fields set")
    func errorEnvelopeFields() {
        let envelope = ServiceEnvelope(
            responseTo: "req-1",
            operationID: "fetch",
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
