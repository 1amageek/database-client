# Core Client

## Purpose and Scope

Owns the platform-independent typed invocation module. Parent:
[Client package](../../DESIGN.md). Child:
[Query invocation](QueryExecution/DESIGN.md).

## Responsibilities and Boundaries

DatabaseClient reserves request identifiers and invokes its injected transport.
DatabaseSessionClient retains the selected target; call and job facades consume
the canonical operation contract. Query invocation owns its logical connection
and page retrieval state. No query interpreter, storage or authentication
authority enters this module.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Client package](../../DESIGN.md) | parent | Invocation, error, transport and target contracts | Composes the core and platform adapters | Package design owns the unchanged protocol behavior |
| [Query invocation](QueryExecution/DESIGN.md) | child | Connection and result retrieval | Adds the common semantic execution surface | The transport remains independently owned |
| [Wire](../../../database-kit/Sources/DatabaseWire/DESIGN.md) | depends on | Correlated bounded operation codecs | Supplies canonical frames and retained pages | No wire grammar is duplicated here |

## Architecture

```text
QueryConnection / job facade -> DatabaseSessionClient -> DatabaseClient
    -> correlated DatabaseCall -> injected DatabaseTransport
```

## Contracts and Invariants

The module consumes the package's canonical call/transport contract. Query
declarations are reexported from their Kit owner. Request reservation stays in
the existing Atomic counter; new connection state stays in its child actor.

## Verification and Change Impact

DatabaseClientTests verifies correlation and typed failures through real codecs.
The package-owned Native and Node harnesses execute those tests; Embedded builds
keep Foundation and platform adapters out of the core graph. Query-specific
success/failure and lifetime evidence is owned by the child design.
