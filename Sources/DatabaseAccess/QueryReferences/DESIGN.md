# Query References

## Purpose and Scope

Status: proposed, unimplemented component. Parent: [DatabaseAccess](../DESIGN.md).
Children: none. Owns immutable entity/query references attached to one named
access handle. Pure construction belongs to Kit, not this component.

## Responsibilities and Boundaries

EntityReference is a named source; ModelEntityReference<Model> carries compiled
model identity. QueryReference and ModelQueryReference<Model> retain the same
resolved handle plus SelectQuery or Kit's Selection<Model> view. These are
runtime-bound access views, not another query algebra, execution engine or
mutable builder. Type names are inferred in ordinary caller code.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Common module | Composes references with access/results | No platform dependency |
| [NamedAccess](../NamedAccess/DESIGN.md) | depends on | Retained generation-bound handle | Supplies execution authority boundary | Alias is diagnostic, not a future lookup key |
| [Kit Fluent](../../../../database-kit/Sources/DatabaseKit/Query/Fluent/DESIGN.md) | depends on | QuerySource, typed fields and existing IR | Owns construction and intrinsic failures | No access handle enters Kit |
| [Results](../Results/DESIGN.md) | depends on | Lazy canonical result | Supplies execute output | No partial model reconstruction |

## Architecture

```text
resolved Database
  -> entity(User.self) / entity(name, schema)
      -> Kit source/projection/filter composition
          -> immutable bound QueryReference
              -> retained handle.execute(.statement(.select(query)))
```

## Contracts and Invariants

- Reference creation performs no I/O and does not create another connection.
  Typed construction uses Model.persistableType and macro-generated Field
  metadata, not reflected type names, KeyPaths or model instances. The current
  application catalog maps these names in public; an explicit schema/source
  override is represented structurally, never parsed from a dotted string.
- select/where/orderBy/limit/offset return new values and preserve the original
  source, alias, partitions and handle. Limit changes QueryPagination only;
  pageSize remains a retrieval option rather than a query rewrite.
- Typed methods only accept fields/predicates from their Model parameter.
  Named methods preserve exact supplied names and use canonical literal
  conversion. A typed field is construction metadata, never permission.
- Pure QuerySource construction is shared through statically dispatched Kit
  functions. Concrete bound methods wrap the result with the same handle;
  they do not add a second overridable interpretation algorithm to Kit.
- Kit's unbound Selection<Model>/SelectQuery can be executed by any explicitly
  selected DB. A bound reference cannot silently change DB: callers explicitly
  obtain its pure definition and pass it to another handle if intended.
- Combining bound sources requires identical access identity and generation,
  not merely matching names/endpoints. A different handle fails with a typed
  crossDatabaseReference error before invocation. Cross-DB Composition remains
  the existing explicit MultiBase capability, not an implicit join.
- execute(options:) delegates once to that handle's common execute family.
  There is no build/buildAST, SQL generation round trip, ambient connection,
  automatic retry or retained transaction in a reference.
- Metadata, if exposed by the common execute overload, is forwarded unchanged
  by the remote adapter. The local adapter must reject nonempty unsupported
  OperationRequestMetadata before effects, including an idempotencyKey; it
  cannot silently claim server idempotency semantics.

## Runtime Flows

Reference construction is synchronous and may fail intrinsically. Execute
unwraps its existing IR, invokes the retained access once, awaits final output
and returns the common result. Later remote retrieval remains in that original
Client stream. No name lookup or backend acquisition occurs inside this flow.

## State, Ownership, and Lifecycle

References are immutable Sendable values retaining a strong access handle and
immutable/COW IR storage. Branching a query shares backing values until changed.
No actor or Mutex belongs to each reference. Their owner is the existing access
generation, which remains closed after shutdown even when the alias is reused.
No mutable current-user closure or subsequent directory lookup is stored.

## Failure, Concurrency, and Constraints

Construction preserves intrinsic typed failures. Binding/type/collation/security
and resource failures remain execution-owned. A reference survives schema
publication as a definition, not a cached plan: execute rebinds under the current
admitted schema generation and rejects invalid/renamed/default-denied sources.
It never carries a physical storage key, schema lease or obsolete policy result.

## Verification and Change Impact

N03 verifies no-I/O creation, immutable branches, two DBs with identical entity
names but distinct contents, pure/bound equivalence, stale-handle rejection,
same-alias/new-generation isolation, qualified names and partitions, forged or
stale field rejection at binding, typed projection ordering/duplicates, join
identity rejection and concurrent use of one base reference. Execute traces must
reach the existing local/remote executor once and retain its meter/authority.
N04 preserves all previously supported SQL builder source metadata during
migration; unsupported new feature paths are explicit typed failures, not empty
success or a different interpretation.
