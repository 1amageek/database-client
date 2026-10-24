# Results

## Purpose and Scope

Status: N01 implemented and behaviorally verified. Parent: [DatabaseAccess](../DESIGN.md).
Children: none. Owns common lazy consumption over existing local/remote final
results. It creates no new row, graph, column, primitive or Wire payload model.

## Responsibilities and Boundaries

Results supplies concrete RowStream and GraphStream carriers conforming to Kit QueryRows
and QueryGraph. Their pages views preserve the original Wire pages. The existing
QueryResult algebra is specialized with these carriers and Bool, or with the
existing QueryBooleanResult when MultiBase is explicitly compiled.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Module composition | Consumes canonical final results | No runtime publication authority |
| [Kit execution](../../../../database-kit/Sources/DatabaseKit/Query/Execution/DESIGN.md) | depends on | QueryResult/QueryRows/QueryGraph/QueryRow | Owns result semantics | Preserve distinct outcomes |
| [Client invocation](../../DatabaseClient/QueryExecution/DESIGN.md) | depends on | Validated row/graph streams and pages | Owns remote retrieval | Never bypass count/progress/identity validation |
| [Framework facade](../../../../database-framework/Sources/Database/QueryExecution/DESIGN.md) | depends on | Authoritatively closed immutable pages | Owns local result publication | Never adapt provisional Engine outputs |

## Architecture

```text
Framework final QueryRowPage / RDFGraphPage -> retained local source
Client QueryRowStream / QueryGraphStream   -> retained remote source
       -> SDK Rows / Graph -> original QueryRow / RDFQuad / pages
```

## Contracts and Invariants

Adapters specialize where concrete carrier/iterator types are known. Small
non-generic source/iterator protocol requirements provide next and page access;
extension-only or generic existential calls are not used. The SDK wrappers
delegate to the existing iterators instead of rebuilding the Client page loop.
An independently created iterator has independent progress; no class box may
accidentally share a mutable iterator between copies. Native/WASM/Embedded must
use the same retention and Sendable contract.

Keep original frame owners, schemas, exact values, annotations, versions,
affected counts, Boolean/provenance, graph/COPY bytes and ordered block members.
No response re-encoding, eager full-page array, per-row lookup dictionary,
automatic model decoding or lossy scalar conversion is introduced. Retained
wrapper storage is bounded by result/iterator structure. Transient async call-frame
costs are measured against direct iteration in N05; allocation-free iteration is
not claimed before that measurement.
Existing lazy row/value materialization remains owned by its existing decoder.

Non-row .rows and block .results retain the current Kit behavior. Duplicate
labels remain positional; this design adds no ambiguous name-based row getter.
Command and block outcomes never become a synthetic empty SELECT result.

## Runtime Flows

Iterator creation specializes/retains its existing source; each next delegates
to that source's iterator. EOF or a terminal typed failure releases iterator
state as its owner requires. Any remote page call stays inside the original
Client consumer; this component performs no alternative retrieval loop.

## State, Ownership, and Lifecycle

Sources retain existing immutable final frames or Client stream values; each
iterator exclusively owns its current underlying iterator. The remote source
retains its original connection through the existing page source. Local page
views expose the already complete bounded result, including when pageSize was
requested; this is not a new local streaming claim. Complete retained values
survive shutdown. Additional remote I/O requires its original access to remain
open. There is no public result.close().

## Failure, Concurrency, and Constraints

Cancellation, malformed page progress, changed metadata/schema/read identity,
delivery-limit violations and decode limits retain the underlying typed error.
The iterator terminates after failure as its underlying consumer requires.
The facade must not add a different continuation loop, unlimited retention or
stream-wide budget promise. No unsafe erasure, runtime type recovery or target
branch bypassing isolation is permitted.

## Verification and Change Impact

N01 tests adapt real local pages and actual Client streams, compare every result
kind including zero rows/duplicate columns/rich values, and cover independent
iterators, terminal errors, close before continuation, page origins, token
cycles and page limits. N05 measures direct versus wrapped iteration with equal
input, output consumption and budgets. Until the exact adapter signatures
compile/link and these paths execute on each target, this remains a design.

### N01 source and cursor boundary

PagedRows and PagedGraph supply fixed-result row/quad/page cursor requirements
in addition to the original typed sequences. Existing Client streams implement
those requirements at their concrete iterator owner; their retrieval and
validation loop bodies remain unchanged. Common carriers retain the source and
invoke only those non-generic witnesses. Iterator mutation happens in place;
no iterator is extracted/copied/reboxed on each row. Independently created or
copied value iterators retain independent progress.

A direct retained page with a continuation is rejected as missingPageSource.
Client streams preserve their original checked continuation source. EOF/failure
is terminal in the common iterator and errors retain the underlying typed cause.
There is no result close operation or new full-page materialization.

| State | Native / ordinary WASM / Embedded | Owner and release |
|---|---|---|
| Page/source backing | Same immutable Sendable storage enum | Carrier retention |
| Cursor and terminal flag | Same exclusive Sendable value state | Each iterator, EOF/failure |
| Client continuation/admission | Existing Client actor and value iterator | Existing checked consumer/close |

The Swift 6.4.0 SDK default next(isolation:) dynamically casts errors to an
associated Failure. Both common and Client iterators implement that witness
explicitly; concrete Client iterators also supply the fixed-result cursor
requirements. No generic AsyncIteratorProtocol bridge or dynamic error cast
remains in common consumption. This is one shared implementation on all targets.
Native and both portable lanes execute these witnesses, not only their modules.

The native and JavaScript harnesses own their exact added test counts.
DatabaseClientTests/AccessResultTests uses actual codecs/client streams and
retained pages. scripts/access-runtime-harness owns matching Swift6.4.0 normal
and Embedded compile/link plus six actual consumption cases on each SDK.
