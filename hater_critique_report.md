# The "Soma" Project: A Masterclass in Over-Engineering and Architectural Fragility

As requested, I have conducted a deep, unsparing review of the Soma project architecture. Simply put, this codebase is a polyglot nightmare. It attempts to be a "fast" local-first evidence compiler but collapses under the weight of its own fragmented process management, dangerous IPC hacks, and baffling design choices.

Here is a merciless breakdown of the worst offenders in this codebase.

---

## 1. The Swift-to-Python Architecture is Fundamentally Broken

The most egregious flaw in this entire system is how the Swift frontend (`SomaMCPCoordinator.swift`) interacts with the Python backend (`soma_mcp_server.py`).

**The Problem:**
For *every single MCP tool call*, Swift uses `Process()` to spawn a brand-new `python3` instance.
It serializes the tool parameters into a JSON string, passes them as command-line arguments to the Python script, waits for the VM to boot, waits for the script to load all its heavy dependencies (JSON, regex, asyncio, AST parsing), executes the single command, and then kills the process.

**Why it's terrible:**
- **Performance:** Python startup time is non-trivial. Spawning a new Python VM for every micro-interaction (like `soma_inspect` or `soma_scene`) completely destroys the "fast, deterministic" mandate described in the README.
- **State Loss:** Because the Python script is invoked strictly as a CLI runner, it cannot maintain any in-memory caching. Every request starts cold.
- **Fragility:** Passing complex JSON payloads as command-line arguments is notoriously brittle and prone to escaping issues.

**The Fix:**
Stop using Python as a CLI script. Re-implement a persistent, long-lived Python backend that communicates with Swift over standard stdio or a local socket (like actual MCP servers do), or port the logic entirely to Swift to avoid the bridge altogether.

---

## 2. The Go Daemon is a Ticking Time Bomb (Race Conditions)

To "speed up" scanning, the Python backend spawns a Go daemon (`go_scanner/daemon.go`). However, the implementation of the IPC mechanism in Go is catastrophically unsafe.

**The Problem:**
In `daemon.go`, the daemon loop reads JSON requests from `stdin`. To capture the output of the requested command, it does this:

```go
rescueStdout := os.Stdout
r, w, _ := os.Pipe()
os.Stdout = w
// ... run command ...
w.Close()
output := <-done
os.Stdout = rescueStdout
```

**Why it's terrible:**
- **Global State Mutation:** It globally hijacks `os.Stdout`. If the Go daemon ever attempts to process two requests concurrently, or if any background goroutine attempts to log anything, the streams will cross, resulting in corrupted JSON output and catastrophic deserialization failures back in Python.
- **Deadlocks:** If the buffer fills up before `w.Close()` is called, the pipe will block indefinitely.

**The Fix:**
Stop hijacking `os.Stdout`. Refactor the individual Go command functions (like `scanFiles`) to return `string` or `[]byte` directly, or pass an `io.Writer` interface to them. Never mutate global standard streams in a daemon loop.

---

## 3. The "Fast" Go Scanner Fails on Real Projects

In `go_scanner/scan.go`, the file discovery logic is crippled by arbitrary and undocumented limitations.

**The Problem:**
```go
const MaxDiscoveredFiles = 1500
```

**Why it's terrible:**
Any moderately sized Unity or web project will easily exceed 1,500 files. When this limit is hit, `scanFiles` silently triggers `filepath.SkipAll`, truncating the project map without any warning to the user or the AI. The LLM will confidently operate on a dangerously incomplete view of the project.

**The Fix:**
Remove the hardcoded limit. If performance is a concern, implement proper tree-shaking, streaming outputs, or utilize `.gitignore` parsing properly instead of capping the array.

---

## 4. The Rust "Scanner" is Lazy and Unsafe

The project delegates parsing heavy Unity files (`.prefab`, `.unity`) to a Rust binary (`rust_scanner/src/main.rs`).

**The Problem:**
Instead of actually parsing the YAML structure of these Unity files, the Rust code just reads line-by-line and does naive string matching:

```rust
if let Some(idx) = line.find("guid:") { ... }
```

**Why it's terrible:**
This is extremely brittle. Unity files often contain string literals, comments, or serialized data that happen to include the word "guid:". This lazy string matching will produce false positives, polluting the AI's context window with garbage references.

**The Fix:**
If you are going to use Rust for performance, use a fast, streaming YAML parser designed for Unity's specific serialization format, rather than grepping lines.

---

## 5. Implicit On-The-Fly Compilation in Python

In `scout_pipeline_module/discovery.py` and `symbols.py`, the Python code does this:

```python
subprocess.run(['go', 'build', '-o', 'soma_scanner', '.'], ...)
subprocess.run(['cargo', 'build', '--release'], ...)
```

**Why it's terrible:**
A production orchestration tool should never implicitly compile its own dependencies on the fly during runtime.
- It assumes the user has a full Go and Rust toolchain installed.
- It silently eats massive amounts of time (especially `cargo build --release`) blocking the main thread while the LLM waits for a response.
- If it fails, it fails silently or masks the error.

**The Fix:**
Pre-compile these binaries during the installation/build phase of the Swift app and bundle them in the macOS `.app` package. Do not leave compilation up to the runtime pipeline.

---

### Conclusion

Soma is a textbook example of "too many cooks" in terms of languages. By mixing Swift, Python, Go, and Rust, the author has created an orchestration bottleneck where serialization overhead and process spawning completely wipe out any performance gains the low-level languages theoretically provide. The architecture needs a severe consolidation and a rewrite of its IPC bridges before it can be considered robust.