# Named Access

## Purpose and Scope

Status: N03 concrete directory and handle implementation contract. Parent: [DatabaseAccess](../DESIGN.md).
Children: none. Owns application aliases, startup publication, generation-bound
handles and authoritative access shutdown.

## Responsibilities and Boundaries

DatabaseDirectory owns a map of configured aliases to handles. A private shared
directory backs Database's static convenience methods; explicit directories
provide isolated application/test composition. It stores access endpoints, not
storage keyspaces, schema handlers, grants or mutable current-user state.

Each alias is an application name. It is not SQL CURRENT_DATABASE, an SQL
namespace, HTTP databaseID, a Base ID or a tenant identifier. Those are explicit
adapter/runtime settings and are never inferred from the alias.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Core](../DESIGN.md) | parent | Public composition | Owns module dependencies | Foundation-independent |
| [References](../QueryReferences/DESIGN.md) | used by | Stable handle identity | Binds a query to one access generation | Never retain just an alias for later lookup |
| [Results](../Results/DESIGN.md) | depends on | Final lazy result carrier | Defines endpoint output | No pre-commit adaptation |
| [Embedded](../../../../database-framework/Sources/DatabaseEmbedded/DESIGN.md) | coordinates with | Owned/borrowed local access | Opens and closes local resources | Container keeps exclusive engine ownership |
| [Remote](../../DatabaseClient/Access/DESIGN.md) | coordinates with | Owned/borrowed remote access | Opens and closes client resources | Credentials are explicit |

## Architecture

```text
Database.configure/configured directory
    -> validate aliases and limits -> open endpoints privately
    -> publish one immutable name table and generation
Database.database(name)
    -> short synchronized lookup -> retained access handle
handle.execute -> original long-lived endpoint -> per-call execution
shutdown -> reject lookup/admission -> drain endpoints -> release owned resources
```

## Contracts and Invariants

- Database.database(name) is synchronous, fallible, performs no I/O and returns
  the existing access identity. Repeated lookup never creates a connection.
- Alias keys use Swift String equality. Empty names fail; no trimming, case
  folding, default-name fallback or implicit backend creation occurs. The
  dictionary input already has unique keys; adapters do not rename them.
- configure validates all aliases and positive per-access concurrency settings
  before invoking openers. It publishes no aliases until every opener succeeds.
  Sequential deterministic opening is sufficient initially; no lock is held
  while opening or closing. A later opener failure/cancellation closes all
  successfully created accesses in reverse acquisition order before returning
  the original failure with its failing alias retained.
- Remote opener success may mean a valid local client/transport configuration,
  not a completed network authentication. The remote adapter owns that distinction.
- Publication atomicity does not undo durable effects of DBContainer bootstrap
  in a different database. It provides resource cleanup and zero partial lookup.
- Configuring a ready directory fails as alreadyConfigured. Concurrent configure
  calls cannot replace one another or publish two generations. Lookup during
  configuring/closing fails explicitly instead of waiting synchronously.
- After awaited shutdown, an explicit configure with fresh owning configurations
  may publish a fresh generation.
  Old handles/references remain bound to the closed old generation, even if its
  alias is reused. They never adopt new credentials, targets or storage owners.
- The directory pins the exact local authorization/session or remote credential
  configuration selected at startup. A different principal requires explicit
  replacement after shutdown, not an ambient global user switch.

Directory generations use retained identity rather than a wrapping/reused
numeric identity. Public shutdown belongs to the directory/application owner;
there is no per-screen or result shutdown requirement. Lower-level borrowed
resources may still be explicitly closed by their external owner; subsequent
execution preserves that underlying closed error without reopening them.

Lookup/bootstrap error cases are notConfigured, configurationInProgress,
alreadyConfigured, shuttingDown, nameNotFound, invalidName and
invalidConcurrencyLimit. Failed initialization retains the alias and original
typed cause; generation/admission failures remain distinguishable from SQL,
transport, authorization and resource-limit errors. No error is an empty result.

## Runtime Flows

```text
unconfigured -> configuring -> ready(generation)
                     |              |
        awaited cleanup on error    v
                     |           closing -> closed
                     v                         |
                unconfigured                   +-> explicit configure -> new generation
```

A shutdown racing configuration cancels/joins the owned initialization work
and waits for cleanup. It cannot return while an unpublished endpoint remains
live. A shutdown racing execute closes admission and joins the existing owned
execution tasks before releasing resources. Multiple shutdown callers await
one completion boundary; caller cancellation cannot abandon cleanup.

## State, Ownership, and Lifecycle

| Logical state | Native / ordinary WASM / Embedded storage and isolation | End |
|---|---|---|
| Directory phase, generation, published map and lifecycle-task references | One identical Mutex<State> and identical mutation entry points | Awaited failure cleanup or shutdown |
| Per-access admitted calls, identifiers and close task | Existing local/Client connection actor; access handle has no second counter/queue | Existing close drain |
| Handle identity and adapter endpoint reference | Immutable retained values | Last owner release; explicit shutdown is still required |
| Query/row page iterator | Exclusive value state or its existing owner | EOF/terminal failure/caller release |

The directory state is authoritative, not mirrored by a second mutable phase
in an actor. Implement async workers outside the lock and publish completion
under a generation/operation check. Await, resource factory calls, adapter close,
event emission and continuation resumption occur outside Mutex.withLock.
Cancellation-safe cleanup must await the same owned work; deinit is not proof.
No Embedded branch may replace the Mutex/actor with raw state or drop Sendable.

## Failure, Concurrency, and Constraints

Concurrency is configured at startup with a positive bound, passed to the
existing connection. The SDK does not rely on the existing raw default of one
slot for a multi-screen application and does not invent a universal new limit.
At capacity, the existing typed rejection is retained; there is no unbounded
queue. Budgets/timeouts remain request-owned. Cancelling one execute does not
close the access or cancel another call. Explicit access shutdown cancels/drains
that access; directory shutdown drains all configured accesses.

The shared convenience directory is for application/login-session composition.
Server request authorization remains explicit as defined by the package's
Server use contract. Tests/servers can own isolated directories; resetting a
global directory to switch one concurrent request's user is invalid.

## Verification and Change Impact

N03 tests must distinguish: lookup before configure, unknown/empty names,
concurrent configure, ready reconfigure rejection, failure at each opener,
cancel/shutdown during startup, no partial publication, identical repeated
lookup identity, two databases with the same entity name and distinct data,
cross-alias resource ownership, lookup/execute/shutdown races, stale references
after reuse of a name, independent cancellation, capacity overflow, cleanup
exactly once, and two concurrently active isolated directories. Every failed
startup proves owned resources unreachable after the awaited return.

Native tests exercise real concurrency; ordinary/Embedded target tests exercise
their available task scheduling and the same storage/entry points. Do not infer
multi-thread semantics from a single-thread WASI runtime. Recheck the state matrix
and conditional-compilation searches before implementation acceptance/commit.

### N02 acquisition configuration

DatabaseConfiguration is an immutable opener plus an explicit positive
maximumConcurrentExecutions. Construction rejects a non-positive bound before
resource acquisition; open() delegates once to DatabaseOpening. Each adapter
opener is single-use and actor-isolated on every target. A failed/cancelled
acquisition cleans up resources already returned by its factory before throwing;
the factory owns anything it acquired before returning/throwing itself.

Factories distinguish owningRemote/borrowingRemote and owningEmbedded/
borrowingEmbedded. An owning factory creates the resource inside open, fixes its
session/context explicitly, and transfers a logical execution scope once.
Adapter execution delegates without another admission queue or meter. Adapter
close coalesces its awaited cleanup, drains the existing connection first and
then shuts down only owned transport/container resources. Cancellation does not
abandon cleanup. All names still remain N03 application-directory concerns.

### N03 concrete ownership

DatabaseProviding defines synchronous lookup; DatabaseQuerying defines the
non-generic execution requirement. DatabaseExecuting keeps its original independent execution/close requirements;
DatabaseQuerying describes the directory-owned handle without exposing close. The immutable Database handle exposes execution and
entity references; its shared application directory owns shutdown. Isolated
DatabaseDirectory instances provide the same configuration/lookup/shutdown flow
for tests and authorization-bound server composition.

A single Mutex<Phase> stores unconfigured/configuring/ready/closing/closed.
Each configuration receives a fresh retained AccessGeneration identity with one
Mutex<Bool> validity bit. Directory shutdown invalidates that generation at its
linearization point; an execute already past the validity check is still
admitted or rejected by the original connection's close boundary. No second
execution counter or queue is added. Directory-to-generation is the sole nested
lock order; handle execution never reads the directory.

Lifecycle Tasks are installed under the phase lock, and their asynchronous
workers acquire resources, cancel/join initialization, close endpoints and await
completion outside the lock. Publication checks the same identity and task
cancellation under the lock. Publication is the configure success boundary; a
caller cancellation that arrives after publication does not undo that success.
A factory failure always preserves its alias and original cause, including a
factory error observed after caller cancellation. Cancellation detected by the
directory itself remains CancellationError. Cleanup closes successful acquisitions in reverse order.
