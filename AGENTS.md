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
  never wraps, and reports exhaustion.
- JavaScript request-completion correlation uses one `Mutex<State>` in the
  shared implementation. It never holds the mutex across `await`, JavaScript
  calls, timer cancellation, or continuation resumption.
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

## Test Harnesses

- Run Native macOS tests with the pinned Swift 6.4 snapshot through
  `scripts/xcode-test-harness`. The harness must inject the snapshot testing
  runtime into the generated `.xctestrun` before executing tests and requires
  exactly 48 passed tests for the standard graph. An isolated `MultipleBases`
  graph uses `DATABASE_CLIENT_EXPECTED_TEST_COUNT=49` and requires 49 passed
  tests. Both runs require zero failures, skips, expected failures, or runtime
  warnings.
- Set `XCODE_TEST_WORK_ROOT` to an explicit absolute temporary directory when
  iterating locally. The harness preserves that DerivedData so subsequent
  corrections compile incrementally; release evidence still executes the
  complete test bundle after the final build.
- Run focused JavaScript/WASI behavior tests with
  `scripts/javascript-test-harness --filter JavaScriptDatabaseTransportTests --expected-tests 9`.
- The final JavaScript/WASI package run is
  `scripts/javascript-test-harness --expected-tests 27`.
  The harness builds the real Swift test runner, packages it with PackageToJS,
  injects the WASI Preview 1 imports required by the compiled module, and
  requires the Swift Testing process termination signal.
- A WASI build or PackageToJS packaging step without the Node runtime test is
  compile evidence only. It is not JavaScript transport verification.
- The JavaScript harness allows 600 seconds for a cold host-macro and WASM
  build; retain the generated `.build` directory for incremental diagnosis.
- The final Embedded gate builds `DatabaseClient` with
  `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-07-23-a_wasm-embedded`. This compile
  and link gate supplements, but does not replace, the Native and Node runtime
  behavior suites.
