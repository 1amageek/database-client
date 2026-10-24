# Database Access

## Purpose and Scope

Status: approved implementation design. This module and library product belong
to the existing `database-client` Swift package and Git repository. No new
repository or Swift package is introduced. Parent: [Client package](../../DESIGN.md).
The foundation remains governed by [SPEC.md](../../../SPEC.md).

The intended API configures named databases during application startup, obtains
the same shared access through `try Database.database("primary")`, creates
typed or named entity references, constructs canonical queries, and executes
through the existing Framework or Client connection. Public initialization of a
handle by name is intentionally absent: lookup does not initialize a database.

Children: [NamedAccess](NamedAccess/DESIGN.md),
[QueryReferences](QueryReferences/DESIGN.md), and [Results](Results/DESIGN.md).
The existing Client module owns [remote composition](../DatabaseClient/Access/DESIGN.md).
The Framework package owns [in-process composition](../../../database-framework/Sources/DatabaseEmbedded/DESIGN.md).

This design covers the Swift API on Native, ordinary WASM, and Embedded WASM.
It does not promise a TypeScript SDK, offline write queue, listener API, automatic
mutation replay, cross-database transaction, or migration of all model persistence
APIs. Studio, Server dispatch, and storage implementations are unchanged.

## Responsibilities and Boundaries

| Owner | Responsibility |
|---|---|
| DatabaseAccess | Application names, shared lookup, access lifetime, bound references, and lazy result adaptation |
| DatabaseEmbedded | Compose a Framework container/context/connection without interpreting queries |
| Remote access composition | Compose an existing Client session/connection and explicitly owned transport |
| DatabaseKit | Pure QuerySource/fluent construction and the existing QueryStatement/SQLBlock/value algebra |
| QueryAST | SQL/SPARQL parsing and canonical serialization |
| Framework | Authorization, binding, planning, exact budgets, transactions, rollback, and authoritative result closure |
| Client | Request correlation, transport invocation, validated continuation retrieval, and no implicit replay |

The semantic owner is client-side invocation and access lifetime. The separate
DatabaseAccess module keeps that common surface independent of remote transport
and in-process execution. DatabaseClient consumes it for remote composition;
Framework's optional DatabaseEmbedded adapter consumes it for local composition.
The Framework execution targets retain their existing dependency direction.
Existing connection/session/context/container APIs remain independently usable.

The user-authorized shared directory is an application access facility. It never
registers global Framework handlers, schemas, indexes, grants, storage roots, or
execution capabilities. Those remain explicitly injected per DBContainer.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Client package](../../DESIGN.md) | parent | Ownership and dependency direction | Owns this common access module | Execution remains Framework-owned |
| [NamedAccess](NamedAccess/DESIGN.md) | child | Startup, lookup and shutdown | Owns named generations | One shared-state contract on all targets |
| [References](QueryReferences/DESIGN.md) | child | Bound query access | Retains pure IR and handle | No additional execution queue |
| [Results](Results/DESIGN.md) | child | Lazy canonical carriers | Retains existing final pages | No payload re-encoding |
| [Embedded adapter](../../../database-framework/Sources/DatabaseEmbedded/DESIGN.md) | coordinates with | Direct Framework invocation | Owns local resource composition | Never dispatches Wire operations |
| [Remote adapter](../DatabaseClient/Access/DESIGN.md) | coordinates with | Client invocation | Owns remote resource composition | Never interprets query semantics |
| [Kit fluent contract](../../../database-kit/Sources/DatabaseKit/Query/Fluent/DESIGN.md) | depends on | Pure canonical construction | Supplies unbound definitions | Contains no runtime handle |
| [Framework facade](../../../database-framework/Sources/Database/QueryExecution/DESIGN.md) | coordinates with | Adapter-provided execution | DatabaseEmbedded consumes this boundary | DatabaseAccess does not import Framework |
| [Client invocation](../DatabaseClient/QueryExecution/DESIGN.md) | depends on | Typed results and continuation validation | Remote execution boundary | Keep its checked page consumer |

## Architecture

The DatabaseAccess product is added to database-client. DatabaseClient reexports
it; the optional DatabaseEmbedded product in database-framework also reexports
it. Applications importing both see one declaration and one application directory.
Dependencies point from consumer to dependency:

```text
database-client:
  DatabaseClient -> DatabaseAccess -> DatabaseKit, DatabaseWire

database-framework:
  DatabaseEmbedded -> DatabaseAccess (database-client product)
  DatabaseEmbedded -> Database, DatabaseEngine

Database.database(name) -> configured directory -> generation-bound handle
  -> entity/query reference -> existing QueryConnection -> common final result
```

The common module declares non-generic DatabaseOpening and DatabaseExecuting
protocol requirements. Adapters specialize their concrete connection and lazy
iterators at construction. No generic or extension-only existential dispatch
is used. The public operations are configure(databases:) async throws,
database(_:) throws, shutdown() async, and equivalent operations on an explicitly
owned DatabaseDirectory. Database's initializer is not a lookup operation.

Application startup assembles its transport-specific opener using existing
Client HTTP/WebSocket/JavaScript products and supplies it to remote access composition.
The opener defers owned acquisition until configure invokes it and supplies
explicit awaited shutdown. This design requires no new SDK platform-factory
targets. access core/remote and the ordinary/Embedded local adapter must not import
Foundation or JavaScriptKit.
The non-default MultiBase trait is forwarded consistently to Kit, Client, and
Framework adapter; the access layer never negotiates v3/v5 or enables MultiBase by default.

## Contracts and Invariants

### Intended application code

All declarations introduced below are proposed. Configuration values are
produced by the adapter factories and contain explicit resource ownership,
authorization, and a positive concurrency limit selected at startup.

```swift
import DatabaseAccess

try await Database.configure(databases: [
    "primary": primaryConfiguration,
    "analytics": analyticsConfiguration
])

let db = try Database.database("primary")
let users = db.entity(User.self)
let query = try users
    .select(#field(\User.name))
    .where(#field(\User.isActive) == true)
    .orderBy(#field(\User.name))
    .limit(20)
let result = try await query.execute()
for try await row in result.rows {
    print(row.values)
}

let events = try Database.database("analytics").entity("events", schema: "public")
let recent = try events.select("name", "timestamp").limit(100)
let eventResult = try await recent.execute()

let minimumAge = Int32(18)
let sqlResult = try await db.execute(
    "SELECT name FROM users WHERE age >= \(minimumAge)"
)
let irResult = try await db.execute(statement)
let blockResult = try await db.execute(block)
```

Entity/selection creation performs no backend I/O. Construction that can reject
invalid literals/structure throws its original typed failure; examples include
`try` rather than suggesting all construction is infallible. Execute still
validates everything against the current schema and original authority.

Pure `User.select(...)` and `TableRef(...).select(...)` remain available through
Kit and return existing IR or a phantom-model view of it; execution requires
`db.execute(definition)`. A bound reference already carries its DB handle.
Neither path exposes build/buildAST or serializes IR back to SQL for execution.

### Preserved lower-level contracts

Results retain the existing QueryResult algebra, positional values, exact
numeric widths, duplicate column labels, annotations, versions, page metadata,
COPY and ordered block outcomes. A partial projection does not create an
incomplete User model. Result decoding convenience is not added in this task.

Existing per-request budgets remain per-request, including each remote page.
The SDK adds no unlimited collection, stream-total budget claim, or weaker
admission. A page size is the existing read-only delivery preference: local
execution currently materializes the complete bounded result; remote execution
may fetch pages. Equal final values do not imply equal memory/streaming behavior.
Paged blocks/effects remain rejected. First SQL statement failure still rolls
back the block. Transport/cancellation errors never trigger automatic mutation
replay; cancellation after commit is not evidence that a write was rolled back.

### Server use

The default shared directory targets a single application/login session. A
server may share immutable configuration, pools and DBContainer owners across
requests, including a process-owned named resource map. It must not share a
mutable current user, authorization-bound QueryConnection, transaction, meter,
or cancellation scope across independent users.

Server's existing request handler continues to derive authorization from its
authenticated OperationContext and obtain its Framework context per request.
An application-owned server obtains a shared container by name, then calls
`container.newContext(authorization: requestAuthorization)` and uses that
request's connection. Only the logical authorization scope is per request;
the storage engine/pool is not reopened. MultiBase uses the corresponding
existing explicit session/target selection. A remote service-account connection
may be shared when that account is deliberately the operation principal; it
does not impersonate each request's user. No TaskLocal/global user inference
or server dispatch rewrite is part of this design.

## Runtime Flows

Application startup, synchronous lookup and awaited shutdown follow the
[NamedAccess lifecycle](NamedAccess/DESIGN.md). Execution
flows through [bound references](QueryReferences/DESIGN.md)
to the selected adapter. Server request composition uses the explicit
authorization boundary described above rather than the default app directory.

## State, Ownership, and Lifecycle

The [named access component](NamedAccess/DESIGN.md) is the
single authority for directory/generation and lifecycle transitions. Adapter
ownership documents define resource acquisition and awaited release. Complete
result frames may outlive shutdown; a later remote page fetch cannot.

## Failure, Concurrency, and Constraints

Lookup is synchronous and throws for absent/unavailable names. Initialization
is async and atomically publishes the name table only after all openers succeed.
This is publication atomicity, not a distributed rollback of durable bootstrap
writes already completed in one database. The shared-state and bounded
concurrency contracts are defined only in NamedAccess.

## Verification and Change Impact

### Current facts and evidence

The inspected production snapshots are Kit b325109, Client d9aa621 and Framework
69bca4a5. Source links below establish current paths; no proposed SDK behavior
is inferred from them.

| Current fact | Source / behavioral owner |
|---|---|
| Local open claims one engine, restores schema, binds runtime/policies, and awaits shutdown on failure | [DBContainer](../../../database-framework/Sources/DatabaseEngine/Core/DBContainer.swift), [DBConfiguration](../../../database-framework/Sources/DatabaseEngine/Core/DBConfiguration.swift) |
| Local connection binds an existing authorization context; close drains calls but not the container | [Local connection](../../../database-framework/Sources/Database/QueryExecution/QueryConnection.swift), [tests](../../../database-framework/Tests/SQLiteTests/QueryConnectionTests.swift) |
| Client connections are transport-generic and retain immutable invocation/target | [Client connection](../DatabaseClient/QueryExecution/QueryConnection.swift), [page source](../DatabaseClient/QueryExecution/QueryPageSource.swift) |
| Continuations validate count, progress, schema and read identity | [Rows](../DatabaseClient/QueryExecution/QueryRowStream.swift), [graph](../DatabaseClient/QueryExecution/QueryGraphStream.swift), [tests](../../Tests/DatabaseClientTests/QueryConnectionTests.swift) |
| HTTP/WebSocket configuration fixes credentials/database headers; network setup can be lazy | [HTTP](../HTTPClient/HTTPDatabaseTransport.swift), [WebSocket](../WebSocketClient/WebSocketDatabaseTransport.swift) |
| Field identity is statically generated, while predicate declarations/operators currently live with runtime evaluation | [Field](../../../database-kit/Sources/DatabaseKit/Model/Field.swift), [typed fetch](../../../database-framework/Sources/DatabaseEngine/Fetch/DatabaseQuery.swift) |
| Builder constructs SelectQuery and independently serializes SQL | [SQLQueryBuilder](../../../database-framework/Sources/QueryAST/Builder/SQLQueryBuilder.swift), [literal tests](../../../database-framework/Tests/QueryASTTests/TypedLiteralBuilderTests.swift) |
| Application SQL catalog names use public plus canonical schema entity names | [Catalog](../../../database-framework/Sources/DatabaseEngine/SQLCatalog/SQLCatalogSnapshot.swift) |

Retained source-matched runtime evidence is indexed by the workspace PAGE24-03
record and `.codex-tools/query-page-fixes-20261024/integration-verification.json`:
Client Native 64/MultiBase 67, ordinary WASM 41, Embedded 12; Framework Native
1798, Linux SQLite 141, ordinary/Embedded scalar witnesses 6+14+9, and an actual
authenticated SQLite HTTP comparison. Those are existing lower-layer proofs,
not SDK tests. Graph-enabled portable SDK behavior remains a future gate.

### Implementation order and acceptance

The following are implementation sprints tracked by NAPI24-N00 through NAPI24-N05
in the workspace PROGRESS task. Each requires its own focused red/green,
owner review, source/doc update and coherent commit; URL-graph integration and
normal upstream push follow the completed implementation task, with no implied
release authorization.

| Sprint | Responsibility and dependency | Required counterexample / completion evidence |
|---|---|---|
| N00 | Kit fluent contracts and predicate declaration split | Typed/mixed-model compile cases; complete SQL literal widths/NULLs/aliases/partitions; no operator ambiguity; existing fetch evaluator stays behaviorally unchanged |
| N01 | Add Client access product/core harness, result wrappers and non-generic adapter protocol declarations, after N00 | Exact rich row/graph/block/COPY/Boolean equality; independent lazy iterators, original pages/provenance and terminal failures; no re-encoding/full-page collection or callable facade stubs |
| N02 | Local and remote open/execute/close adapters, after N01 | Real SQLite and authenticated HTTP SQL/IR/block parity, default deny, work/row/byte failures, late-error rollback, restart and close; owned versus borrowed cleanup |
| N03 | Named access and bound references, after N02 | Atomic publication, failed/cancelled startup cleanup, same-handle lookup, per-DB isolation, generation invalidation, no-I/O construction and bounded shared execution |
| N04 | Public construction migration, after N03 | Existing Builder callers and tests migrate to Kit without losing joins/CTEs/window/graph source metadata; remove superseded public Builder implementation; serializer stays QueryAST |
| N05 | Integrated app/server and target matrix, after N00-N04 | Native/ordinary WASM/Embedded compile+link+runtime, shared app aliases, separate authenticated server requests, final URL graph and measured adapter overhead |

Package harnesses retain their reviewed exact-count owners and external
timeouts. The access harness must pin its compiler/SDK identities and own
its counts. Benchmarks compare direct versus SDK invocation with equal budgets,
audit settings and inputs: lookup, construction, 1/100/10,000 output rows and
concurrency 1/4/8 where configured capacity permits. Verify results outside the
timed region and report latency, throughput, peak retained memory and wrapper
allocations. No threshold or default concurrency is guessed in this design;
accept no payload-sized extra retention, no unbounded queue, and no duplicate
encoding/decoding. Investigate and report measured overhead before acceptance.

All planned types, factory signatures and adapters require the target-specific
compile/runtime evidence above. No new SDK implementation was executed during
this design task.
