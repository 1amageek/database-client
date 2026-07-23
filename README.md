# database-client

`database-client` is the transport-facing client for the canonical `DatabaseWire` protocol.
Database semantics remain owned by the database runtime.

## Products

| Product | Runtime | Responsibility |
|---|---|---|
| `DatabaseClient` | Swift 6.4+ application and Embedded environments | Typed operation calls, request correlation, bounded `DatabaseWire` encode/decode |
| `DatabaseClientWorker` | Hosted Worker runtime | Promise and `Uint8Array` transport |
| `DatabaseClientHTTP` | Apple and Linux | Authenticated URLSession transport |
| `DatabaseClientWebSocket` | Apple and Linux | Persistent WebSocket transport with request-ID correlation |

The dependency boundary is intentionally one-way:

```text
DatabaseClient
        │
        ├── DatabaseClientWorker
        ├── DatabaseClientHTTP
        └── DatabaseClientWebSocket
```

`DatabaseClient` is the Foundation-free core of the Embedded dependency graph. It
depends on `DatabaseWire`, `QueryIR`, and Foundation-free value types.
`DatabaseClientWorker` adds only the Worker boundary needed by hosted Embedded
WebAssembly. Foundation and URLSession remain isolated to the network adapter products.

## Byte ownership

`DatabaseBytes` is the owned byte type across the client and wire layers. Request and response
values are passed by ownership sharing, payload decoding returns constant-time slices,
and exact-size encoders transfer their final array storage through copy-on-write.

Copies exist only where a foreign runtime requires a different owner:

| Boundary | Request | Response | Reason |
|---|---:|---:|---|
| `DatabaseTransport` | 0 | 0 | Both sides exchange `DatabaseBytes` owners |
| JavaScriptKit | 1 | 1 | JavaScript `Uint8Array` and Swift memory have independent lifetimes |
| URLSession HTTP | 1 | 1 | `URLRequest` and returned `Data` expose Foundation-owned storage |
| URLSession WebSocket | 1 | 1 | Binary frames are represented by Foundation-owned `Data` |

The adapters copy directly between the foreign buffer and the final owner. They do not create
an intermediate `[UInt8]` payload.

## Typed calls

Every operation statically associates its request and response types.

```swift
let transport = WorkerDatabaseTransport()
let client = DatabaseClient(transport: transport)

let capabilities = try await client.execute(
    CapabilitiesDescribeOperation.self,
    request: DatabaseEmpty(),
    metadata: DatabaseRequestMetadata(traceID: traceID)
)
```

`DatabaseClient` allocates a `UInt64` request ID, builds the canonical envelope, sends it
through `DatabaseTransport`, validates response correlation, and decodes the typed
response. A remote failure is returned as `DatabaseRemoteError` through
`DatabaseCallError.remote`.

For split-phase runtimes, `DatabaseCall<Operation>` exposes encoding and response decoding
without owning a transport.

## Worker request contract

`WorkerDatabaseTransport` calls a global async request entrypoint named
`__databaseExecute` by default. The entrypoint accepts and returns `Uint8Array` and must
preserve bytes exactly.
The returned value may be an offset view. The transport copies exactly the view's
`byteOffset..<byteOffset + byteLength` range once into Swift-owned storage; it never widens
the response to the complete backing `ArrayBuffer`.

```javascript
globalThis.__databaseExecute = async (request) => {
  const id = env.CALENDAR_DATABASE.idFromName("calendar")
  const stub = env.CALENDAR_DATABASE.get(id)
  return stub.execute(request)
}
```

The JavaScript boundary does not parse queries, schemas, indexes, or transactions.

## HTTP transport

`HTTPDatabaseTransport` posts `application/octet-stream` and applies the configured
authorization and database scope headers. It rejects oversized Foundation responses before
the one ownership copy into `DatabaseBytes`.

```swift
let configuration = try HTTPDatabaseConfiguration(
    endpoint: endpoint,
    accessToken: accessToken,
    databaseID: "calendar"
)
let client = DatabaseClient(
    transport: HTTPDatabaseTransport(configuration: configuration)
)
```

## WebSocket transport

`WebSocketDatabaseTransport` keeps one WebSocket connection, correlates responses by
the envelope request ID, and supports concurrent callers. Call `shutdown()` when the owning
application stops.

## Embedded verification

Pin the compiler and SDK to the same Swift snapshot. For the currently validated snapshot:

```bash
/Users/1amageek/Library/Developer/Toolchains/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a.xctoolchain/usr/bin/swift \
  build \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-17-a_wasm-embedded \
  --product DatabaseClient
```

The same command with `--product DatabaseClientWorker` verifies the Worker transport
inside a true Embedded WebAssembly build.

## Development dependency

During the coordinated multi-repository replacement, `Package.swift` references the adjacent
`../database-kit` checkout. The release step replaces this path with the canonical release tag
after `database-kit` and its golden vectors are published.
