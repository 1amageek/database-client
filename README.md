# database-client

Type-safe Swift client SDK for [database-framework](https://github.com/1amageek/database-framework). KeyPath-based queries, change tracking, and WebSocket transport — powered by [QueryIR](https://github.com/1amageek/database-kit).

## Requirements

- Swift 6.2+
- iOS 18+ / macOS 15+ / tvOS 18+ / watchOS 11+ / visionOS 2+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/database-client.git", branch: "main"),
]
```

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "DatabaseClient", package: "database-client"),
    ]
)
```

## Usage

### Connect

```swift
import DatabaseClient

let config = ClientConfiguration(
    url: URL(string: "ws://localhost:8080/db")!,
    authToken: "sk-xxx"
)
let context = try await DatabaseContext(configuration: config)
```

### CRUD

`DatabaseContext` uses a change tracking pattern — stage changes with `insert` / `delete`, then commit with `save()`.

```swift
context.insert(User(name: "Alice", age: 30))
context.insert(User(name: "Bob", age: 25))
try await context.save()

context.delete(user)
try await context.save()
```

### Query

Build queries with KeyPath-based predicates and sorting.

```swift
let result = try await context.find(User.self)
    .where(\.age > 20 && \.name != "Admin")
    .sort(by: \.name)
    .limit(20)
    .execute()

for user in result.items {
    print(user.name)
}
```

### Pagination

```swift
let firstPage = try await context.find(User.self)
    .limit(20)
    .execute()

if firstPage.hasMore {
    let nextPage = try await context.find(User.self)
        .limit(20)
        .continuation(firstPage.continuation!)
        .execute()
}
```

### Get by ID

```swift
let user = try await context.get(User.self, id: "user-001")
```

### Partition (Multi-tenant)

```swift
let orders = try await context.find(Order.self)
    .partition(["tenantId": "tenant_123"])
    .where(\.status == "shipped")
    .execute()
```

### Count

```swift
let count = try await context.find(User.self)
    .where(\.age >= 18)
    .count()
```

## Architecture

```
┌─ Public API ─────────────────────────────────┐
│ DatabaseContext                               │
│   .insert(item) / .delete(item) / .save()    │
│   .find(Type.self)                           │
│     .where(\.field > value)  ← KeyPath ops   │
│     .sort(by: \.field)                       │
│     .execute()               → [T]           │
└──────────────┬───────────────────────────────┘
               │ QueryIR.Expression (Codable)
┌─ Internal ───▼───────────────────────────────┐
│ DatabaseTransport (protocol)                 │
│   ├─ WebSocketTransport                      │
│   └─ InProcessTransport (testing)            │
└──────────────┬───────────────────────────────┘
               │ ServiceEnvelope (JSON)
               ▼
         database-framework server
```

### Shared Query Interface

Client and server share the same query representation via **QueryIR**. The KeyPath operators (`\.age > 20`) produce `QueryIR.Expression` trees that are serialized as Codable JSON and evaluated server-side — no separate client/server query languages.

### Testing

Use `InProcessTransport` to test without a network connection:

```swift
let transport = InProcessTransport { envelope in
    // Handle request and return response
}
let context = DatabaseContext(transport: transport)
```

## License

MIT
