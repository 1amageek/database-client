# database-client

Type-safe Swift client SDK for [database-framework](https://github.com/1amageek/database-framework). KeyPath-based queries, change tracking, and WebSocket transport.

## Overview

database-client provides a native Swift API for iOS and macOS apps to interact with a database-framework server. Models defined in [database-kit](https://github.com/1amageek/database-kit) are shared between client and server — the same `@Persistable` structs work on both sides.

```
┌──────────────────────────────────────────────────────────┐
│                      database-kit                        │
│  @Persistable models, IndexKind protocols, QueryIR       │
└──────────┬───────────────────────────────┬───────────────┘
           │                               │
           ▼                               ▼
┌─────────────────────┐       ┌─────────────────────────┐
│  database-framework │       │    database-client       │
│  FDBContainer       │◄─────│    DatabaseContext        │
│  Index Maintainers  │  WS  │    KeyPath queries       │
│  FoundationDB       │       │    iOS / macOS           │
└─────────────────────┘       └─────────────────────────┘
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/database-client.git", from: "26.0207.0"),
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

## Quick Start

### Connect

```swift
import DatabaseClient

let config = ClientConfiguration(
    url: URL(string: "ws://localhost:8080/db")!,
    authToken: "your-token"
)
let context = try await DatabaseContext(configuration: config)
```

### CRUD

`DatabaseContext` uses a change-tracking pattern — stage changes, then commit with `save()`.

```swift
// Insert
context.insert(User(name: "Alice", age: 30))
context.insert(User(name: "Bob", age: 25))
try await context.save()

// Delete
context.delete(user)
try await context.save()
```

### Query

KeyPath-based predicates compile to `QueryIR.Expression` — the same representation used server-side.

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

### Get by ID

```swift
let user = try await context.get(User.self, id: "user-001")
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
┌─ Transport ──▼───────────────────────────────┐
│ DatabaseTransport (protocol)                 │
│   ├─ WebSocketTransport (production)         │
│   └─ InProcessTransport (testing)            │
└──────────────┬───────────────────────────────┘
               │ ServiceEnvelope (JSON)
               ▼
         database-framework server
```

### Shared Query Model

Client and server share the same query representation via **QueryIR** (from database-kit). KeyPath operators (`\.age > 20`) produce `QueryIR.Expression` trees that are serialized as JSON and evaluated server-side.

### Testing

Use `InProcessTransport` to test without a network connection:

```swift
let transport = InProcessTransport { envelope in
    // Return mock response
}
let context = DatabaseContext(transport: transport)
```

## Platform Support

| Platform | Minimum Version |
|----------|-----------------|
| iOS | 18.0+ |
| macOS | 15.0+ |
| tvOS | 18.0+ |
| watchOS | 11.0+ |
| visionOS | 2.0+ |

## Related Packages

| Package | Role | Platform |
|---------|------|----------|
| **[database-kit](https://github.com/1amageek/database-kit)** | Model definitions, IndexKind protocols, QueryIR | iOS, macOS, Linux |
| **[database-framework](https://github.com/1amageek/database-framework)** | Server-side index maintenance on FoundationDB | macOS, Linux |

## License

MIT License
