# DatabaseClient

## Purpose and Scope

This document is the package design authority for `database-client`. The
package turns a typed canonical database operation into DatabaseWire request
bytes, sends those bytes through an injected transport, and decodes the
correlated typed response.

It is the remote entry point of the workspace. It never embeds a database: it
holds no container, no storage engine, no query plan, and no schema authority.
Everything it sends is meaningful only because `database-kit` owns the wire
contract and `database-server` implements the other end of it.

- Parent: [Database workspace](../DESIGN.md).
- Children: none. This package declares no module-level design authority.
- Operating contract and verification expectations: [AGENTS.md](AGENTS.md).

This document does not restate wire field layout, operation identity, or
`DatabaseWireLimits` semantics; those belong to
[database-kit](../database-kit/DESIGN.md).

## Responsibilities and Boundaries

The package produces five library products: one core and four transport
adapters. The split exists so an application links exactly one transport and
never pulls another platform's runtime into its graph.

| Product | Target path | Owns |
|---|---|---|
| `DatabaseClient` | `Sources/DatabaseClient` | typed call construction, request identifier reservation, encode/decode against DatabaseWire, session and job surfaces, the `DatabaseTransport` contract, and the client error algebra |
| `DatabaseClientHTTP` | `Sources/HTTPClient` | request/response over `URLSession`, response body ownership, and HTTP configuration validation |
| `DatabaseClientWebSocket` | `Sources/WebSocketClient` | connector and connection contracts, frame correlation, retired request identifiers, and frame byte ownership |
| `DatabaseClientFramedStream` | `Sources/FramedStreamClient` | a length-framed connection contract for a caller-supplied stream |
| `DatabaseClientJavaScript` | `Sources/JavaScriptClient` | JavaScript promise adaptation, pending-request correlation, and request deadlines under WASI |

The core owns:

- The single transport contract: `send(ByteString) async throws(DatabaseTransportError) -> ByteString`.
  A transport carries bytes and nothing else.
- Request identifier reservation: an `Atomic<UInt64>` starting at one that never
  wraps and reports `requestIdentifierExhausted` instead of reusing an
  identifier.
- Correlation of a response to its request identifier at decode time.
- The typed failure algebra that keeps a transport failure, a wire failure, a
  remote operation failure, and a job failure distinguishable.
- The session-bound and job surfaces built on those primitives.

It does not own:

- The wire format, operation identity, query semantics, schema, graph
  semantics, or model declarations. Those belong to `database-kit`.
- Primitive values and byte ownership. Those belong to `database-types`.
- Query execution, transactions, indexes, or storage. Those belong to
  `database-framework` and `storage-kit`; the client depends on neither.
- Server admission, authorization, durable job storage, or response
  production. Those belong to `database-server`.
- Connection policy such as retry, backoff, or failover. A transport reports a
  typed failure and the caller decides.

A transport adapter must not interpret the bytes it carries. It has no
dependency on `DatabaseKit` semantics beyond `ByteString` and the transport
error type.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Database workspace](../DESIGN.md) | parent | system index and semantic plane assignment | Places this package as the remote access plane. | It is a peer consumer of the wire contract, not a consumer of Framework. |
| [database-kit](../database-kit/DESIGN.md) | depends on | `DatabaseOperation`, `DatabaseWireEncoder`/`Decoder`, `DatabaseWireLimits`, `OperationRequestMetadata`, `RemoteOperationError`, `JobIdentity`, and under `MultiBase` `DatabaseOperationTarget` | Supplies the entire canonical remote vocabulary. | The client never re-encodes, extends, or reinterprets a wire field. A kit wire change is a client-breaking change. |
| [database-types](../database-types/AGENTS.md) | depends on | `ByteString` and `ByteStringOwner` | Supplies owned request and response bytes. | External runtime memory is adopted through a `ByteStringOwner`, not copied through an intermediate array. |
| [database-server](../database-server/DESIGN.md) | peer across the wire; no package dependency | DatabaseWire request and response framing | Implements the responding side of every operation this client issues. | Neither package may depend on the other. Compatibility is established through the shared kit version, not through a shared type. |
| [database-cli](../database-cli/DESIGN.md) | used by | `DatabaseClient` plus one transport | The CLI is a consumer that adds profiles, credentials, and output. | Command, profile, and credential concerns must not move into the client. |
| [AGENTS.md](AGENTS.md) | operating authority | responsibility, naming, concurrency, and harness rules | Owns the exact toolchain, harness invocation, and expected test counts. | Expected counts are read from `AGENTS.md`; this document does not duplicate them. |

## Architecture

```text
application / CLI / JavaScript host
        |
        v
DatabaseSessionClient<Transport>          typed, target-bound surface
   execute / startJob / jobStatus / cancelJob / jobResult
        |
        v
DatabaseClient<Transport>                 final class, Sendable
   reserveRequestID()  Atomic<UInt64>, starts at 1, never wraps
        |
        v
DatabaseCall<Request, Response>
   encode(limits:)          -> DatabaseWireEncoder  (database-kit)
   decodeResponse(_:limits:) -> DatabaseWireDecoder, matched to requestID
        |
        v  ByteString in, ByteString out
   protocol DatabaseTransport
        |
   +----+----------+----------------+-------------------+
   |               |                |                   |
HTTPDatabase   WebSocketDatabase  FramedStream       JavaScriptDatabase
Transport       Transport         DatabaseTransport   Transport
(actor,         (actor,           (actor,             (struct + Mutex
 URLSession)     connector)        connection)         + deadline actor)
        |
        v
   database-server

DatabaseClient -X-> database-framework / storage-kit
DatabaseClient -X-> database-server
```

Under the `MultiBase` trait, `DatabaseCall` and `DatabaseClient.execute` gain a
`DatabaseOperationTarget`, and `DatabaseSessionClient` carries that target so a
job's status, result, and cancellation reach the same target that created it.
The trait is not enabled by default and is forwarded to `database-kit` only
when the consumer selects it, so a single-base deployment never encodes a
target field.

## Contracts and Invariants

- A transport completes each request exactly once, with response bytes or a
  typed `DatabaseTransportError`. Timeout and cancellation are distinct
  failures and never become success.
- A request identifier is reserved before encoding, is never reused, and is
  never zero. Exhaustion is reported, not wrapped.
- A response is accepted only when it matches the reserved request identifier.
  A mismatched or malformed response is a decode failure, not an empty result.
- A remote failure reaches the caller as `.call(.remote(_))` carrying the
  server's `RemoteOperationError`. It is never flattened into a transport error
  or into a default value.
- The job surface validates identity before use: a status, cancellation, or
  result response for a different job is `mismatchedJob`, and a paged result
  additionally validates continuation identity, continuation index, page
  digest, and total byte count before the page is accepted.
- Owned `ByteString` values are preserved through the core path. Bytes produced
  by an external runtime are adopted through a `ByteStringOwner`
  (`HTTPResponseByteOwner`, `ReceivedWebSocketFrameByteOwner`) and copied at
  most once, directly into the final owner.
- The core target admits neither Foundation, `Codable`, `URLSession`, nor
  JavaScriptKit, so it remains buildable for Embedded WASM. Those dependencies
  exist only inside the transport adapters that require them.
- This is version 1. A superseded API is removed rather than kept as a
  compatibility path.

## Runtime Flows

### Single operation

```text
reserve requestID (atomic, non-wrapping)
  -> build DatabaseCall(operation, requestID, [target], metadata, request)
  -> encode with DatabaseWireLimits          -> .call(.wire) on failure
  -> transport.send(requestBytes)            -> .transport(_) on failure
  -> decodeResponse matched to requestID     -> .call(.wire) on failure
  -> Result.failure(RemoteOperationError)    -> .call(.remote(_))
  -> typed Response
```

### Durable job

```text
startJob   -> JobIdentity, validated against the response
jobStatus  -> identity-checked status
jobResult  -> per page: identity, continuation identity and index,
              digest, and total byte count validated before acceptance
cancelJob  -> identity-checked cancellation
```

Every job call goes through the same `DatabaseSessionClient`, so under
`MultiBase` the target selected at creation is preserved for the whole job
lifecycle rather than re-derived per call.

## State, Ownership, and Lifecycle

| State | Owner | Allowed transition |
|---|---|---|
| next request identifier | `DatabaseClient` `Atomic<UInt64>` | monotonic reservation; exhaustion is terminal |
| in-flight HTTP request | `HTTPDatabaseTransport` actor | one response or one typed failure; `shutdown()` ends the session |
| WebSocket connection and pending frames | `WebSocketDatabaseTransport` actor | correlate by request key; retired identifiers reject late frames |
| framed-stream connection | `FramedStreamDatabaseTransport` actor | ordered framed exchange over a caller-supplied connection |
| pending JavaScript request | `PendingJavaScriptRequest` `Mutex<State>` | resolve, reject, or expire exactly once |
| JavaScript request deadline | `JavaScriptRequestDeadline` actor | arm, fire, or cancel; never resumes a continuation twice |

Transports that own an ordered asynchronous connection are actors. The
JavaScript adapter uses a mutex only for short request-correlation state and
never holds it across `await`, a JavaScript call, timer cancellation, or
continuation resumption.

## Failure, Concurrency, and Constraints

- `DatabaseClientError` keeps five distinguishable causes: identifier
  exhaustion, transport, call, job lifecycle, and job result.
- `DatabaseTransportError` distinguishes unavailability, timeout, cancellation,
  explicit rejection with a code, an invalid request, and an invalid response.
  A transport must not collapse these.
- The client does not retry, does not substitute a cached response, and does not
  replace a malformed response with an empty one.
- Configuration is validated at construction. Each transport has its own typed
  configuration error rather than a shared untyped one.
- Platform reach differs per product and is expressed in the manifest: the
  JavaScript adapter is WASI-only in the test graph, HTTP and WebSocket are
  host-platform only, and the core plus framed-stream adapter build everywhere
  the package supports.

## Verification and Change Impact

Expected counts, the pinned toolchain, and the exact harness invocation are
owned by [AGENTS.md](AGENTS.md). This table maps each invariant to the gate that
falsifies it.

| Invariant | Required evidence |
|---|---|
| typed call, correlation, and error algebra hold | native graph through `scripts/xcode-test-harness` with the snapshot testing runtime injected into the generated `.xctestrun` |
| the `MultiBase` target binding holds end to end | isolated `MultiBase` native graph selected by `DATABASE_CLIENT_TEST_TRAITS` |
| the JavaScript transport resolves, rejects, and expires correctly | `scripts/javascript-test-harness` executing the packaged runner under Node, not a PackageToJS build alone |
| the core stays Embedded-capable | release build of `DatabaseClient` on the pinned Embedded WASM SDK |
| HTTP and WebSocket adapters preserve byte ownership and correlation | the transport suites in the native graph, including the scripted and sequenced connector fixtures |

Change impact:

- A `database-kit` wire or operation change invalidates every encode/decode
  path here and requires re-running both native graphs before the dependency
  moves.
- A change to `DatabaseTransport` invalidates all four adapters at once; that
  is intentional, because the contract is deliberately one method wide.
- A change to job identity or paging validation invalidates the job suites and,
  because the server produces those responses, requires confirming the server
  contract at the same kit version.
- Adding a dependency to the core target that Embedded WASM cannot build
  invalidates the Embedded gate and is rejected regardless of native results.
