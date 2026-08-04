# database-client

`database-client` is the transport-facing client for the canonical `DatabaseWire` protocol.
Database semantics remain owned by the database runtime.

## Products

| Product | Runtime | Responsibility |
|---|---|---|
| `DatabaseClient` | Swift 6.4+ application and Embedded environments | Typed operation calls, request correlation, bounded `DatabaseWire` encode/decode |
| `DatabaseClientJavaScript` | JavaScript-hosted WASI runtime | Promise and `Uint8Array` transport |
| `DatabaseClientHTTP` | Apple and Linux | Authenticated URLSession transport |
| `DatabaseClientWebSocket` | Apple and Linux | Persistent WebSocket transport with request-ID correlation |

The dependency boundary is intentionally one-way:

```text
DatabaseClient
        │
        ├── DatabaseClientJavaScript
        ├── DatabaseClientHTTP
        └── DatabaseClientWebSocket
```

`DatabaseClient` is the Foundation-free core of the Embedded dependency graph. It
depends directly on `DatabaseWire` and the Foundation-free primitives in
`DatabaseTypes`. Query and operation payload contracts remain owned by
`database-kit`.
`DatabaseClientJavaScript` adds only the JavaScript promise boundary needed by
hosted Embedded WebAssembly. Foundation and URLSession remain isolated to the
network adapter products.

## Byte ownership

`ByteString` is the owned byte type across the client and wire layers. Request and response
values are passed by ownership sharing, payload decoding returns constant-time slices,
and exact-size encoders transfer their final array storage through copy-on-write.

Copies exist only where a foreign runtime requires a different owner:

| Boundary | Request | Response | Reason |
|---|---:|---:|---|
| `DatabaseTransport` | 0 | 0 | Both sides exchange `ByteString` owners |
| JavaScriptKit | 1 | 1 | JavaScript `Uint8Array` and Swift memory have independent lifetimes |
| URLSession HTTP | 1 | 0 or 1 | `URLRequest` requires `Data`; one response fragment is retained, while multiple fragments are assembled once |
| URLSession WebSocket | 1 | 0 | The received Foundation `Data` owner is retained by `ByteString` |

Adapters retain a compatible immutable foreign owner when possible. When a copy
is required, they copy directly into the final owner and do not create an
intermediate `[UInt8]` payload.

## Typed calls

Every operation statically associates its request and response types.

```swift
let transport = JavaScriptDatabaseTransport()
let client = DatabaseClient(transport: transport)

let capabilities = try await client.execute(
    DatabaseOperations.capabilitiesDescribe,
    request: EmptyOperationPayload(),
    metadata: OperationRequestMetadata(traceID: traceID)
)
```

`DatabaseClient` allocates a `UInt64` request ID, builds the canonical envelope, sends it
through `DatabaseTransport`, validates response correlation, and decodes the typed
response. A remote failure is returned as `RemoteOperationError` through
`DatabaseCallError.remote`.

For split-phase runtimes, `DatabaseCall<Request, Response>` retains the concrete
operation value and exposes encoding and response decoding without owning a
transport.

## Concurrency contract

The same state-isolation contract applies to Native, WASM, and Embedded builds.
Target selection never removes synchronization.

| Logical state | Storage | Read and mutation entry point | External work |
|---|---|---|---|
| Core request identifiers | `Atomic<UInt64>` | Compare-and-exchange reservation | Encoding and transport calls occur after reservation |
| JavaScript promise completion | `Mutex<State>` | `withLock` completion transition | Promise handlers, timers, tasks, and continuation resumption occur outside the lock |
| HTTP request lifecycle | `Mutex<State>` | `withLock` lifecycle transition | URLSession calls, task cancellation, and continuation resumption occur outside the lock |
| WebSocket connection and pending requests | `actor` isolation | Actor methods | Frame I/O suspends without a mutex-held critical section |

Identifier spaces never wrap and reuse a live generation. Exhaustion is reported
as a typed failure.

## JavaScript request contract

`JavaScriptDatabaseTransport` calls a global async request entrypoint named
`__databaseExecute` by default. The entrypoint accepts and returns `Uint8Array` and must
preserve bytes exactly.
The returned value may be an offset view. The transport copies exactly the view's
`byteOffset..<byteOffset + byteLength` range once into Swift-owned storage; it never widens
the response to the complete backing `ArrayBuffer`. The bridge reads intrinsic
TypedArray metadata rather than overridable JavaScript properties and rejects
invalid, detached, oversized, or changing views as typed transport failures.

Synchronous exceptions from the entrypoint are returned as
`database_entrypoint_threw`; Promise rejection is returned as
`database_entrypoint_rejected`. Timeout and task cancellation detach both
Promise handlers before completing the Swift continuation, so a late settlement
cannot decode bytes or retain the pending request.

```javascript
globalThis.__databaseExecute = async (request) => {
  const id = env.DATABASE.idFromName("main")
  const stub = env.DATABASE.get(id)
  return stub.execute(request)
}
```

The JavaScript boundary does not parse queries, schemas, indexes, or transactions.

## HTTP transport

`HTTPDatabaseTransport` posts `application/octet-stream` and applies the configured
authorization and database scope headers. It rejects oversized Foundation responses before
retaining a single response fragment or assembling fragmented response bytes once.

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
application stops. Shutdown rejects new sends, cancels the receive loop and all
per-request send/timeout tasks, closes the connection, and does not return until
those child tasks have completed. Concurrent shutdown callers join the same
completion boundary.

## Embedded verification

Pin the compiler and SDK to the same Swift snapshot. For the currently validated snapshot:

```bash
/Users/1amageek/Library/Developer/Toolchains/swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a.xctoolchain/usr/bin/swift \
  build \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a_wasm-embedded \
  --product DatabaseClient
```

The same command with `--product DatabaseClientJavaScript` verifies the
JavaScript transport inside a true Embedded WebAssembly build.

## Versioned dependencies

`Package.swift` resolves `database-kit`, `database-types`, and JavaScriptKit from
their published release tags. A checkout of another database repository next
to this package is not part of the build contract.
