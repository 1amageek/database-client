# DatabaseClient

The approved [common access module](Sources/DatabaseAccess/DESIGN.md) owns
named application access. The existing Client module owns its remote adapter.
The optional Framework adapter consumes DatabaseAccess; this package gains no
Framework or storage dependency.

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
- Children: [HTTP transport](Sources/HTTPClient/DESIGN.md) and
  [WebSocket transport](Sources/WebSocketClient/DESIGN.md), and
  [Core client](Sources/DatabaseClient/DESIGN.md), plus
  [common access](Sources/DatabaseAccess/DESIGN.md). Other target
  responsibilities remain composed by this package in the current scope.
- Operating contract and verification expectations: [AGENTS.md](AGENTS.md).

This document does not restate wire field layout, operation identity, or
`DatabaseWireLimits` semantics; those belong to
[database-kit](../database-kit/DESIGN.md).

## Responsibilities and Boundaries

The package produces a common access product, one remote invocation core and
four transport adapters. The split exists so an application links exactly one transport and
never pulls another platform's runtime into its graph.

| Product | Target path | Owns |
|---|---|---|
| `DatabaseAccess` | `Sources/DatabaseAccess` | named access composition, execution/opening contracts and common lazy result carriers; no interpreter, transport or storage |
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
| [database-types](../database-types/AGENTS.md) | depends on | `ByteString` and `ByteStringOwner` | Supplies owned request and response bytes. | External ownership may be retained only with an accurately bounded lifetime/allocation; otherwise copy directly to the final ByteString owner. |
| [HTTP transport](Sources/HTTPClient/DESIGN.md) | child | bounded Foundation response conversion | Owns URLSession response/body adaptation. | Data views do not expose retained allocation capacity. |
| [WebSocket transport](Sources/WebSocketClient/DESIGN.md) | child | bounded received frame conversion | Owns actor-isolated frame receive/correlation/lifecycle. | Copies at the Data receive boundary before canonical Wire admission. |
| [database-server](../database-server/DESIGN.md) | peer across the wire; no package dependency | DatabaseWire request and response framing | Implements the responding side of every operation this client issues. | Neither package may depend on the other. Compatibility is established through the shared kit version, not through a shared type. |
| [database-cli](../database-cli/DESIGN.md) | used by | `DatabaseClient` plus one transport | The CLI is a consumer that adds profiles, credentials, and output. | Command, profile, and credential concerns must not move into the client. |
| [AGENTS.md](AGENTS.md) | operating authority | responsibility, naming, concurrency, and harness rules | Selects the exact toolchain and harness invocation. | Executable harness configuration owns exact native test counts; this document does not duplicate them. |

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
- Owned `ByteString` values are preserved through the core path. External
  runtime memory is retained only when its ownership and retained allocation
  can be bounded accurately. The HTTP and WebSocket child designs own their
  Foundation receive conversion; these boundaries copy directly into one final
  ByteString owner because Data does not expose retained allocation capacity.
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

Executable harness configuration owns exact native test counts;
[AGENTS.md](AGENTS.md) selects the pinned toolchain and invocation. This table
maps each invariant to the gate that falsifies it.

| Invariant | Required evidence |
|---|---|
| typed call, correlation, and error algebra hold | native graph through `scripts/xcode-test-harness` with the snapshot testing runtime injected into the generated `.xctestrun` |
| the `MultiBase` target binding holds end to end | isolated `MultiBase` native graph selected by `DATABASE_CLIENT_TEST_TRAITS` |
| the JavaScript transport resolves, rejects, and expires correctly | `scripts/javascript-test-harness` executing the packaged runner under Node, not a PackageToJS build alone |
| the core stays Embedded-capable | release build of `DatabaseClient` on the pinned Embedded WASM SDK |
| HTTP and WebSocket adapters preserve bounded byte ownership and correlation | the transport suites in the native graph, including sliced Data, typed query page decode and the scripted/sequenced cancellation fixtures |

Native macOS retains the pinned August 14 snapshot. JavaScript/WASI uses the
existing Swift 6.4.0 release compiler (`org.swift.640202609131a`) and matching
`swift-6.4.0-RELEASE_wasm` SDK; formal Embedded uses that same release compiler
and `swift-6.4.0-RELEASE_wasm-embedded`. The JavaScript harness checks the selected
toolchain's exact bundle identifier before build, so an Xcode fallback cannot
satisfy the release gate. Native snapshot evidence is not formal WASM evidence.

The native harness accepts repeatable `--only-testing` selectors only with
`--expected-count`; full-run counts remain package-owned. Every invocation
performs `build-for-testing` before `test-without-building` and injects the
snapshot Testing runtime into either supported xctestrun layout. It verifies
the August 14 snapshot directory and compiler commit, launches Xcode through
XcodeDefault with an explicit `SWIFT_EXEC`, and requires that compiler path in
the build log.

`--diagnostic-source-root` copies a separate prepared tree with absolute local
Kit dependencies into the harness-owned source directory. Conditional trait
forwarding is preserved; standard and MultiBase selection changes only that
isolated manifest. This mode is explicitly local diagnostic evidence, not the
URL final gate. Source/prepared manifests and pins retain their SHA-256 digests;
nonlocal URL pins must match the original graph after resolution/build/test.
Input digests, dependency paths, resolved pins, raw logs and unique xcresults
remain beside the result. No invocation substitutes old compiled test products
for the mandatory build stage.

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

## Planned SQL Invocation Preservation

S01 already migrates the current query operation's parameters and row pages to
the [Kit QueryValue/QueryColumn contract](../database-kit/Sources/DatabaseKit/Query/DESIGN.md#s01-public-query-boundary)
and [bounded Wire grammar](../database-kit/Sources/DatabaseWire/DESIGN.md#s01-frozen-query-codec-contract).
Direct source consumers import QueryColumn and QueryValue from DatabaseKit;
Wire does not retain aliases or re-export declarations to conceal the move.
DatabaseCall and DatabaseSessionClient consume the changed codecs; transport
send/correlation state remains opaque ByteString. No transport-specific SQL
conversion, JSON reconstruction or first-row schema inference is introduced.

The response page retains ordered typed columns even when rowCount is zero.
Iterators preserve positional cells, duplicate labels and rich metadata after
the transport's temporary response scope ends, retaining the original byte
owner. Materializing a page remains an explicit bounded call. A malformed
column/type/value/page is a Wire call failure before acceptance, never a NULL
or empty response. Standard and MultiBase fixtures migrate together while v5
target/provenance semantics remain unchanged.

S01-C10/C11/C13 evidence uses actual encode/send/decode and lazy iteration for
duplicate/empty columns and each rich value, including invalid-tag/type/arity
responses and last-owner release. Native core/transport suites, the actual
JavaScript/WASI harness and pinned Embedded core build retain their existing
owners; no new backend execution belongs here. Expected counts remain in the
package harness. S17 block dispatch remains a later responsibility.

## S17 Complete SQL Calls

The canonical operation is DatabaseOperationCatalog.queryExecute, owned by
[DatabaseWire](../database-kit/Sources/DatabaseWire/DESIGN.md). QueryInput carries
SQL/SPARQL text, QueryStatement or SQLBlock with parameters and one execution
budget. Client.openConnection and QueryConnection.execute expose one invocation
family; the existing session executes the canonical call without parsing text,
rendering IR, inferring access mode or replaying effects.

```text
owned SQL / statement / block + parameters + budget
    -> connection.execute -> session.execute(queryExecute, request, metadata)
        -> request ID -> bounded codecs -> injected transport
        -> correlated canonical result after authoritative execution closure
            -> rows / Boolean / RDF / COPY / commands / ordered block
```

Complete execution is the default. Explicit read paging retains the original
request identity and fetches only admitted snapshots; it never replays mutations.
Connection close drains active invocations without shutting down its separately
owned transport. Retained complete results remain usable after close. Under
MultiBase the explicit target is preserved; the server owns target and operation
admission. The client does not infer a target from SQL.

Query rows preserve column ordinals, duplicate labels, type/typmod metadata,
typed NULL, numeric display scale, array dimensions, JSON/JSONB distinction,
and mixed interval values through the canonical Kit codecs. Each retained
row/COPY byte value remains valid after the frame's lexical decode scope and
transport shutdown. Materialization remains bounded by the Wire contract.
`RemoteOperationError` retains the canonical typed SQL diagnostic supplied by
Kit; the client preserves it without recreating SQLSTATE from messages.
Timeout, cancellation, malformed bytes, correlation mismatch and commit-unknown
remain distinguishable failures rather than empty or synthetic results.

| Invariant | S17 falsifiable evidence owner |
|---|---|
| Generic invocation preserves ordered response alternatives and declared row values | Native core tests send the new operation through encode/transport/decode; empty rows, duplicate labels and rich values remain exact. |
| Remote diagnostics and correlation remain typed | New-operation tests reject mismatched request IDs and malformed diagnostic metadata, and preserve SQLSTATE, source position and identifiers in remote failures. |
| Retained data outlives transport and response scope | Native transport tests retain decoded rows and COPY bytes after shutdown and verify byte/value identity and bounded ownership. |
| JavaScript carries the same operation and failure contract | Actual JavaScript/WASI runtime tests execute success, failure and cancellation; packaging alone is insufficient. |
| Core remains platform independent | Exact formal ordinary and Embedded WASM compile/link/runtime evidence exercises the new declaration through the existing client. |

The Framework's transaction, rollback and SQL semantic corpus is not duplicated
in client unit tests. Real backend execution through the public operation is
owned by S17's end-to-end integration lane. Kit, Server, Client and CLI use the
same frozen task-source dependency graph; final URL integration remains S18.

## IR-centered Execution Integration

[Query Execution](../database-kit/Sources/DatabaseKit/Query/Execution/DESIGN.md) owns the directly consumed contract for the accepted QueryStatement/SQLBlock unification. Existing authorization, exact work budgets, first-error rollback, retained ownership and authoritative shutdown remain required. Runtime state and publication do not move into Kit declarations.
