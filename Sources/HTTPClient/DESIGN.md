# HTTP Transport

## Purpose and Scope

Parent: [DatabaseClient package](../../DESIGN.md). Children: none. This module
owns URLSession invocation and bounded HTTP body conversion into the canonical
transport ByteString. It does not interpret SQL, schema or query result meaning.

## Responsibilities and Boundaries

HTTPDatabaseTransport owns request/header validation and status/error mapping.
HTTPDatabaseSession and its response coordinator own URLSession task completion,
cancellation and shutdown. HTTPDatabaseResponseBody owns bounded fragment
collection and final byte assembly. Wire codecs own typed operation decoding.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | DatabaseTransport bytes and typed failures | Composes HTTP with the client core. | Transport contains no SQL or storage execution. |
| [DatabaseWire](../../../database-kit/Sources/DatabaseWire/DESIGN.md) | used by | root-retention admission and lazy result views | Client decodes the returned canonical bytes. | Unknown retained capacity is an explicit failure, not visible-length substitution. |
| [DatabaseTypes](../../../database-types/DESIGN.md) | depends on | final ByteString owner and synchronous copy borrow | Provides accurately bounded immutable response storage. | Data.count is not external allocation capacity. |

## Architecture

```text
URLSession delegate Data fragments
  → coordinator's bounded request body
      → completion removed from Mutex state
          → direct copy into final owned ByteString
              → client Wire decode → lazy result page
```

## Contracts and Invariants

Foundation Data may retain an enclosing allocation whose capacity is not
publicly measurable. At this external receive boundary, both one and multiple
fragments are copied directly into final ByteString storage, without an
intermediate Array or a fabricated Data capacity. Known ByteString ownership is
preserved after this boundary. Empty bodies remain empty owned values.

Response size is checked before retaining each fragment and content length
before accepting the body. Fragment copy runs outside the coordinator Mutex.
Request bytes also have one explicit Foundation Data ownership copy at their
existing send boundary. No additional copy is introduced in the client core.

## State, Ownership, and Lifecycle

The coordinator isolates short request-correlation state with Mutex; external
callbacks, URLSession I/O, continuation resumption and response assembly occur
outside the critical section. Each request completes once. The copied response
owns its storage independently of Foundation fragment lifetime and remains
usable after transport shutdown and through lazy Wire iteration.

## Failure, Concurrency, and Constraints

Oversized bodies, transport failures, timeout, cancellation and invalidated
sessions remain typed failures. Copying cannot convert a failed or incomplete
request into success. Native-only Foundation code does not enter Embedded/WASI
core targets; no shared-state synchronization contract changes in this task.

## Verification and Change Impact

[Body tests](../../Tests/DatabaseClientTests/HTTPDatabaseResponseBodyTests.swift)
prove exact bytes, known final retention, sliced Data detachment, fragment
limits and direct consolidation.
[Transport tests](../../Tests/DatabaseClientTests/HTTPDatabaseTransportTests.swift)
exercise the actual URLSession delegate path and typed QueryExecute decode,
including duplicate result columns and retained values after shutdown. Existing
status/size/shutdown cases remain regression obligations. The package native
harness owns exact counts and timed behavioral execution; source or compile
inspection alone does not establish these behaviors.
