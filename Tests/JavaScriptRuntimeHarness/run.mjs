import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

const [packageDirectoryArgument, ...testArguments] = process.argv.slice(2);

if (!packageDirectoryArgument) {
    console.error("Usage: node run.mjs <packaged-test-directory> [test arguments]");
    process.exit(64);
}

const packageDirectory = path.resolve(packageDirectoryArgument);
const instantiateModule = await import(
    pathToFileURL(path.join(packageDirectory, "instantiate.js"))
);
const { SwiftRuntime } = await import(
    pathToFileURL(path.join(packageDirectory, "runtime.js"))
);
const wasiModule = await import(
    pathToFileURL(
        path.join(
            packageDirectory,
            "node_modules",
            "@bjorn3",
            "browser_wasi_shim",
            "dist",
            "index.js"
        )
    )
);
const {
    WASI,
    File,
    OpenFile,
    ConsoleStdout,
    PreopenDirectory,
} = wasiModule;

const standardInput = new OpenFile(new File([]));
const standardOutput = ConsoleStdout.lineBuffered((line) => console.log(line));
const standardError = ConsoleStdout.lineBuffered((line) => console.error(line));
const rootDirectory = new PreopenDirectory("/", new Map());
const wasi = new WASI(
    [instantiateModule.MODULE_PATH, ...testArguments],
    [],
    [standardInput, standardOutput, standardError, rootDirectory],
    { debug: false }
);
const wasmPath = path.join(packageDirectory, instantiateModule.MODULE_PATH);
const moduleBytes = new Uint8Array(await readFile(wasmPath));
const module = await WebAssembly.compile(moduleBytes);
let receivedTerminationSignal = false;

process.on("beforeExit", () => {
    if (!receivedTerminationSignal) {
        console.error(
            "The Swift test runner ended without a WASI proc_exit termination signal."
        );
        process.exitCode = 1;
    }
});

const swift = new SwiftRuntime({});
const unsupportedBridgeImports = {};
for (const descriptor of WebAssembly.Module.imports(module)) {
    if (descriptor.module === "bjs") {
        unsupportedBridgeImports[descriptor.name] = () => {
            throw new Error(`Unexpected BridgeJS import: ${descriptor.name}`);
        };
    }
}
const wasiImports = {
    ...wasi.wasiImport,
    proc_exit(code) {
        receivedTerminationSignal = true;
        process.exit(code);
    },
};
const instance = await WebAssembly.instantiate(module, {
    javascript_kit: swift.wasmImports,
    bjs: unsupportedBridgeImports,
    wasi_snapshot_preview1: wasiImports,
});
console.log(`WASM linear memory: ${instance.exports.memory.buffer.byteLength} bytes`);

// JavaScriptKit requires the instance before WASI runs static constructors.
// Those constructors install the async executor before the test entry point.
swift.setInstance(instance);
wasi.inst = instance;
const installTestExecutor = instance.exports.database_client_install_test_executor;
if (typeof installTestExecutor !== "function") {
    throw new Error("The JavaScript test executor bootstrap export is missing");
}
installTestExecutor();
wasi.initialize(instance);
globalThis.__databaseCapturedRequest = undefined;
globalThis.__databaseCancellationWasInvoked = false;
globalThis.__databaseRequestLimitInvocationCount = 0;
globalThis.__databaseLateResponseDecodeProbeCount = 0;
globalThis.__databaseExecute_success = (request) => {
    globalThis.__databaseCapturedRequest = Array.from(request);
    const backing = new Uint8Array([0xaa, 7, 8, 9, 0xbb]);
    return Promise.resolve(backing.subarray(1, 4));
};
globalThis.__databaseExecute_rejection = () => Promise.reject("denied");
globalThis.__databaseExecute_synchronous_throw = () => {
    throw new Error("synchronous denial");
};
globalThis.__databaseExecute_timeout = () => new Promise(() => {});
globalThis.__databaseExecute_late_response = () =>
    new Promise((resolve) => {
        setTimeout(() => {
            const response = new Uint8Array([1]);
            const decodeProbe = new Proxy(response, {
                getPrototypeOf(target) {
                    globalThis.__databaseLateResponseDecodeProbeCount += 1;
                    return Reflect.getPrototypeOf(target);
                },
            });
            resolve(decodeProbe);
        }, 20);
    });
globalThis.__databaseExecute_cancellation = () => {
    globalThis.__databaseCancellationWasInvoked = true;
    return new Promise(() => {});
};
globalThis.__databaseExecute_request_limit = () => {
    globalThis.__databaseRequestLimitInvocationCount += 1;
    return Promise.resolve(new Uint8Array());
};
globalThis.__databaseExecute_response_limit = () =>
    Promise.resolve(new Uint8Array([1, 2, 3]));
globalThis.__databaseExecute_not_promise = () => undefined;
swift.main();
