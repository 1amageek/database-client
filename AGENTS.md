# AGENTS.md

## Responsibility

- The core client turns a typed canonical database operation into DatabaseWire
  request bytes, sends those bytes through an injected transport, and decodes
  the correlated typed response.
- Transport products adapt that contract to JavaScript promises, HTTP, or WebSocket APIs. They do not interpret queries, schemas, graph semantics, transactions, or storage operations.
- Request correlation state is short in-memory state. It must not serialize transport I/O.
- Primitive values come from `DatabaseTypes`; query, schema, and operation
  contracts come from `database-kit`. The client must not relocate either
  contract merely to simplify its dependency graph.

## Naming

- Name declarations for their client-domain responsibility, observable behavior, event, ownership, or lifecycle contract.
- Follow the Swift API Design Guidelines at every access level, including tests and host-boundary support.
- Do not name ordinary declarations after implementation language, ABI, calling convention, module identity, binary format, toolchain, build mode, or memory-layout strategy.
- A platform term is valid only for a user-selected transport adapter. Keep fixed host symbol spellings in configuration constants and give their Swift wrappers semantic names.
- Name callbacks for the completion event or state transition they handle. Names such as `regular`, `legacy`, `impl`, `helper`, `manager`, or a bare `callback` are invalid.
- Distinguish owned request or response bytes from temporary borrowed views.

## Concurrency, Data, and Error Contracts

- The Embedded request identifier source uses `Atomic<UInt64>`, starts at one,
  never wraps, and reports exhaustion. Embedded code does not depend on
  `Mutex`.
- A platform adapter may use a mutex only for short request-correlation state
  when that platform provides it. Never hold it across `await` or transport
  I/O.
- A transport must complete each request exactly once with bytes or a typed transport error. Cancellation and timeout must not become success.
- Preserve owned `ByteString` values through the core path. Copy only when an
  external runtime cannot retain Swift memory; copy directly into the final
  owner without an intermediate array.
- Foundation, Codable, URLSession, and JavaScriptKit must not enter the Embedded core target.
- Do not silently retry, replace malformed responses, or return cached success after transport or decode failure.
- This is version 1. Remove superseded APIs instead of retaining compatibility paths.
