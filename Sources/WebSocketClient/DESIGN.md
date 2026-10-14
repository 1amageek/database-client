# WebSocket Transport

## Purpose and Scope

Parent: [DatabaseClient package](../../DESIGN.md). Children: none. This module
owns WebSocket connection adaptation, actor-isolated request/frame correlation
and received byte ownership, without interpreting operation payload semantics.

## Responsibilities and Boundaries

The transport actor owns connection generations, pending/retired request IDs,
send/receive child tasks, cancellation, timeout and authoritative shutdown.
Injected connectors/connections own their network operations. Wire owns header
and payload validation; the client core owns typed operation results.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | DatabaseTransport and typed failure | Composes WebSocket with the client. | Payloads remain opaque to the transport. |
| [DatabaseWire](../../../database-kit/Sources/DatabaseWire/DESIGN.md) | depends on | response header correlation and root admission | Validates canonical frame bytes before typed result use. | Visible Data length does not bound external retention. |
| [DatabaseTypes](../../../database-types/DESIGN.md) | depends on | final ByteString ownership | Supplies bounded immutable receive storage. | No pointer escapes its synchronous copy borrow. |

## Architecture

```text
connection.receive → binary Data
  → configured visible-length check
      → direct copy into final owned ByteString
          → decode header → match request/connection generation
              → join send/timeout children → complete request
                  → client typed decode and lazy iteration
```

## Contracts and Invariants

Foundation Data has no public retained allocation capacity, including slices.
Each accepted binary receive frame is copied directly into final ByteString
storage before Wire header/root admission. No intermediate Array or invented
Data capacity is used. The existing outbound Foundation Data copy is unchanged.
After this explicit external ownership boundary, client/Wire stages retain the
owned bytes and lazy views.

## State, Ownership, and Lifecycle

All pending/connection state remains on the transport actor. A response matches
its connection generation and request ID; retired IDs isolate late frames.
The response is independently owned after the temporary Data scope and remains
valid after shutdown. Shutdown joins existing child operations and completes
pending requests once; receive conversion changes no state-machine ordering.

## Failure, Concurrency, and Constraints

Oversize/text/malformed/unmatched frames, cancellation and timeout remain typed
failures. Copying occurs only after the configured frame-length gate. No retry,
synthetic success, unchecked sharing or target-specific synchronization change
is introduced.

## Verification and Change Impact

[WebSocket tests](../../Tests/DatabaseClientTests/WebSocketDatabaseTransportTests.swift)
exercise injected real transport receive/correlation and typed QueryExecute
response decoding from sliced Data, with known response capacity and lazy page
use after shutdown. Existing timeout, cancellation, late-frame, connection
generation and concurrent-shutdown cases remain the lifecycle evidence. The
native package harness owns execution counts and results; compile alone is not
behavioral evidence.
