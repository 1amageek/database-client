# Remote Access Composition

## Purpose and Scope

Status: implemented remote adapter component. Parent: [Core Client](../DESIGN.md).
Children: none. Owns remote access composition over existing Client sessions.
This component consumes DatabaseAccess within DatabaseClient. The application's lazy opener
assembles HTTP/WebSocket/JavaScript transports with existing Client products and
supplies the concrete session plus explicit owned shutdown. This module adds
no platform-factory targets; Foundation stays out of its dependency graph.

## Responsibilities and Boundaries

Implement DatabaseOpening/DatabaseExecuting with the concrete transport type
known at adapter construction. Keep DatabaseClient<Transport>, its selected
DatabaseSessionClient<Transport> and QueryConnection<Transport> intact; there
is no requirement to erase/rewrite Client's generic implementation. Specialize
the small result adapters at this boundary instead.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core Client](../DESIGN.md) | parent | Invocation composition | Owns module boundaries | No Framework/Server dependency |
| [Common access](../../DatabaseAccess/DESIGN.md) | depends on | DatabaseOpening/DatabaseExecuting and lazy results | Supplies the shared application contract | No query interpretation |
| [NamedAccess](../../DatabaseAccess/NamedAccess/DESIGN.md) | used by | Prepared endpoint publication | Owns named access | Alias does not set HTTP databaseID |
| [Results](../../DatabaseAccess/Results/DESIGN.md) | depends on | Lazy stream adaptation | Wraps Client streams/pages | Preserve checked consumers |
| [Client invocation](../QueryExecution/DESIGN.md) | depends on | Execute, continuation and close | Owns remote calls | No implicit retries |
| [HTTP](../../HTTPClient/DESIGN.md) | coordinates with | Native transport lifecycle | HTTP factory consumes this contract | Credential/database headers are explicit |
| [WebSocket](../../WebSocketClient/DESIGN.md) | coordinates with | Awaited native socket shutdown | WebSocket factory consumes this contract | Share transport only with explicit ownership |

## Architecture

```text
owned transport opener / borrowed Client session
    -> existing QueryConnection<Transport>
        -> Client invoke / original continuation consumer
            -> common results wrappers
close -> connection.close -> owned transport.shutdown
```

## Contracts and Invariants

Owning factories create and retain a transport with an explicit async shutdown
operation and one Client connection. Borrowing factories retain a caller-owned
Client/session and close only the SDK-owned logical connection. Factory names
and configuration distinguish ownership; a shared transport is never
implicitly adopted. Partially opened resources are closed before opener failure.

Configure validates local settings and creates logical access. Existing HTTP
and WebSocket transports can perform network setup on first send; configure
does not claim a completed remote authentication handshake. Actual server
authorization occurs on every request. Credentials, endpoint, database/tenant/
workspace and optional MultiBase target are fixed by the adapter, never inferred
from the application alias. Different-user/server use needs explicit independent
credential/session composition, not a caller-supplied local principal field.

execute forwards the original input, parameters, options and metadata to Client.
The existing connection handles correlation, concurrency, cancellation and
continuation requests. Results wrap its streams without bypassing page count,
cycle, schema, metadata or read-identity checks. No parser, fallback database,
query interpreter, model reconstruction, offline queue or mutation replay is
introduced. A closed access cannot initiate another page fetch.

## Runtime Flows

The opener validates settings, obtains the configured owned/borrowed session
and opens its logical connection. Each invocation delegates to that connection;
continuation consumption uses its original request and metadata. Shutdown first
drains the connection and then awaits only the explicitly owned transport.

## State, Ownership, and Lifecycle

Transport correlation/tasks stay in existing transport owners. Query admission
and close stay in the existing connection actor. Adapter endpoint references
and ownership mode are immutable. After connection.close has drained all its
calls, an owning adapter invokes/awaits transport shutdown; a borrowing adapter
leaves it available. SDK reconfiguration never mutates an old transport's
credentials or changes an old result's page source.

## Failure, Concurrency, and Constraints

Transport timeout/cancellation, correlation errors, typed remote SQL/resource/
authorization errors and terminal page failures retain their original causes.
No new retry rule is inferred from a long-lived handle. The core accepts only
the explicitly configured concurrency bound and keeps Client's overflow error.
All SDK state/Sendable contracts are identical across supported targets.

## Verification and Change Impact

N02 executes real authenticated HTTP against an isolated SQLite-backed Server,
compares direct Client versus SDK rows/graphs/commands/blocks, checks default
deny and rollback, and proves negative readiness after owned teardown. N03
uses two aliases and distinct server targets/credentials to detect misrouting.
Client's existing real JavaScript/WASI tests remain lower-layer proof; N05 must
execute the actual SDK adapter on ordinary/Embedded targets. HTTP/WebSocket
products are never substituted into an Embedded graph to make it compile.

### N02 concrete composition

DatabaseConfiguration.owningRemote receives a lazy transport factory, an explicit
session selector (defaulting to the ordinary database session), an awaited
transport shutdown operation and existing Wire limits. borrowingRemote retains
an already selected external session. Both require a positive concurrency bound.
The private RemoteOpening actor claims one use before I/O. RemoteExecution owns
only its cleanup task; its nonisolated execute forwards input, parameters,
options and metadata to the existing connection and wraps its final streams.
Original errors and ordered result kinds are preserved. No second execution
phase, counter, timeout, retry or query evaluator is added.
