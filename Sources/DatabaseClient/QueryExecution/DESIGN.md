# Query Invocation

## Purpose and Scope

Owns the client query connection and retained row/graph retrieval. Parent:
[DatabaseClient module](../DESIGN.md). Children: none.

## Responsibilities and Boundaries

The connection sends Kit QueryInput through canonical query.execute. It never
parses text, renders IR, grants access or retries effects. The existing typed
DatabaseSessionClient retains target and transport invocation authority.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Client module](../DESIGN.md) | parent | Transport invocation and correlation | Composes this surface | Closing a logical connection never shuts down its transport |
| [Kit](../../../../database-kit/Sources/DatabaseKit/Query/Execution/DESIGN.md) | depends on | SQL, QueryInput, QueryResult, QueryRows and options | Common semantics | No client SQL parser or implicit replay |
| [Framework](../../../../database-framework/Sources/Database/QueryExecution/DESIGN.md) | coordinates with | Matching execution surface | Local implementation | Complete results publish after authoritative closure |

## Architecture

```text
client/session.openConnection -> QueryConnection actor
    -> execute(SQL / QueryStatement / SQLBlock / QueryInput)
    -> existing correlated DatabaseClient.execute(query.execute)
    -> QueryResult with retained row/graph sequences
        -> optional next-page call using the original immutable invocation
```

## Contracts and Invariants

Complete execution is the default. Explicit page size selects the server's
read-only delivery profile; effects must be rejected before execution. Every
fetch preserves input, parameters, partitions, target, metadata and request
budget. Schema, outcome kind, read identity and continuation progress are
validated; failures never become empty success. Initial and continuation responses
must not exceed the original explicit page size; the connection checks decoded
row/quad counts before publication. Only row, graph and Boolean outcomes are valid
for paged requests; block, command and COPY envelopes fail before adaptation, so
a block wrapper cannot bypass the count check. Complete requests retain all outcome
kinds. This delivery bound does not change the
server's per-request execution budget. Per-page origins may differ: only
composition resolution and consistency remain fixed. The pages view preserves
all original Wire page metadata, including typed provenance; the rows/graph view
flattens only values. Transport failures never replay.

Rows/graphs retain immutable initial results. Each iterator retains its current
page and releases that iterator at EOF; an independently retained result may
still own its initial frame. No accumulated row/quad array is created. Continuation
tokens are detached at the retrieval boundary to avoid retaining expired pages.
A shared QueryContinuationProgress value belongs exclusively to each page iterator.
It uses a doubling-window cycle check with one retained checkpoint token and fixed
integer counters, including saturating window growth. Every adjacent repeated token
is rejected immediately; longer cycles are rejected once a checkpoint repeats,
which may take multiple pages. It performs no extra fetches and keeps no token
history or accumulated values. Both rows and graphs use the same algorithm; a
progress failure is terminal and preserves the existing typed error.

## State, Ownership, and Lifecycle

| State | Native / WASM / Embedded owner and isolation | End |
|---|---|---|
| phase, execution identifiers and active tasks | Same QueryConnection actor | open -> closing -> closed |
| active transport call | Existing client/transport contract | exactly one typed outcome |
| current row/quad iterator and continuation checkpoint | Exclusive value iterator, same Sendable storage on Native/WASM/Embedded | EOF, typed terminal failure or caller release |
| result frames | Caller-owned immutable pages | Last retained owner ends |

Close stops admission, cancels and awaits all admitted calls. Individual execute
callers retain errors; close only drains their completion. Cancellation of the
closing caller cannot cancel its independent drain task. Complete values may be
read after close; another network fetch requires the connection to remain open.

## Failure, Concurrency, and Constraints

One execution slot is the default; explicit positive multiplexing is bounded
and rejects overflow rather than queueing without a bound. All target profiles
use identical actor state and Sendable contracts. The core imports no Foundation
or platform transport runtime. Use Task.isCancelled and await Task.value so the
same cancellation/drain contract is available on the fixed Embedded SDK.

## Verification and Change Impact

Client tests cover exact input/result carriage, interpolation, page identity and
progress (including prefixed cycles and long acyclic chains), initial/follow-up
row/quad size violations, terminal failure, error/correlation preservation,
cancellation, no retry, close/drain and
shared-transport survival. Native standard/MultiBase and the existing real Node
transport harnesses supplement final real HTTP and Embedded differential tests.
