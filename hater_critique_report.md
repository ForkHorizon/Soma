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

## 6. Blind Global File Parsing without Tree-Shaking
In `scout_pipeline_module/discovery.py`, `detect_project_type` relies on listing the *entire* root directory. This does not take into account massive build folders, monorepo structures, or properly `.gitignore`'d content, unnecessarily burning CPU and memory enumerating irrelevant files before any useful filtering is done.

## 7. Appalling Exception Swallowing
Across `scout_pipeline_module` (specifically `utils.py`, `git.py`, `gather.py`), the codebase abuses `except Exception: pass`.
```python
try:
    stdout = daemon.call('git-diff', *args)
    return json.loads(stdout)
except Exception:
    pass
return None
```
This is the cardinal sin of debugging. If the daemon crashes, if the JSON is malformed, if the `git` command fails—the user and the LLM see absolutely nothing. It just fails silently, leaving the system in an unknown, corrupted state.

## 8. State Leaks in Swift Views
The SwiftUI codebase (`ContentView.swift` / `SomaViewModel.swift`) binds complex UI logic and state (like `scoutTranscript` or `relayPrompt`) directly to massive `ObservableObject` classes. There is zero separation of concerns between UI state, network requests, process management, and business logic. It's a massive, tangled "God object" masquerading as an MVVM architecture.

## 9. Fragile Python Environment Assumptions
In `SomaViewModel+Execution.swift`, the code assumes the user has a globally configured Python environment with exact pip packages installed via `PATH` manipulation:
```swift
environment["PATH"] = ... ":/usr/local/bin:/opt/homebrew/bin:/Users/daliys/.local/bin..."
```
This hardcodes specific user directories (`/Users/daliys`) and completely breaks portability. Any user attempting to run this app natively will encounter immediate failures if their Python or node setup differs.

## 10. Memory Leaks in Go Logger
In `go_scanner/logs.go`, the `tailLogs` function reads files directly into a massive memory slice (`var errors []string`), only stopping at an arbitrary limit of 1000 items. There is no streaming serialization; it just buffers thousands of lines in RAM, marshals them into a giant JSON blob, and spits them into stdout, causing huge memory spikes for large log files.

## 11. Redundant File System Round-Tripping
The pipeline calculates git status via Go, sends it as JSON to Python, then Python parses the JSON, looks at the file paths, and re-scans those paths using Python utilities (`iter_project_files`). This forces the OS to read the same file metadata multiple times across different processes.

## 12. Regex Guesswork for AST Parsing
`classifier.py` and `symbols.py` use simplistic Regex string matching to guess prompt intent and extract file symbols.
```python
prompt_terms(prompt): return [token for token in re.findall('[a-z0-9_./-]+', prompt.lower()) ...]
```
Using Regex to parse intent and tokens from complex LLM prompts or code structure is incredibly naive and guarantees massive amounts of noise and false positives.

## 13. UI Freezing and Thread Starvation
In `SomaViewModel+Execution.swift`, the app runs heavy synchronous JSON encoding and process initialization on `Task` threads without proper isolation or actor boundaries. The usage of `.userInitiated` global queues mixed with `MainActor.run` creates massive thread contention and UI jank during gathering phases.

## 14. Useless Error Boundaries in Swift
In `SomaMCPCoordinator.swift`:
```swift
} else {
    let errorStr = String(data: errorData, encoding: .utf8) ?? "Unknown python error"
    throw MCPError.toolExecutionFailed(errorStr)
}
```
If Python fails silently (which it does, constantly, due to point #7), `errorData` is empty, and Swift just throws "Unknown python error". The user gets no traceback, no log context, and no way to recover.

## 15. The "Token Calculator" is a Guessing Game
The pipeline relies on `estimate_tokens` in Python, which is simply counting characters or whitespace (`len(text) / 4`). It does not use the actual tokenizer specific to the target model (e.g., Tiktoken for Codex, or Gemma's specific tokenizer). This leads to wildly inaccurate budget enforcement, causing the LLM to either truncate output or fail the context window constraint.

## 16. O(N) Substring Searching
In Go's `tailLogs`, it loops over every line and does `strings.Contains` for a fixed array of tokens (`"ERROR"`, `"EXCEPTION"`, etc.).
```go
for _, token := range tokens {
    if strings.Contains(upper, token) { ... }
}
```
For large log files, doing an `O(N * M)` string substring scan on every single line, combined with string allocation for `strings.ToUpper(line)`, creates massive GC pressure and completely defeats the purpose of writing a "fast" Go daemon.

## 17. The Hardcoded Graphify Dependency
`SomaViewModel+Status.swift` hardcodes paths to `uv` and `graphify` binaries:
```swift
let uvPath = "/Users/daliys/.local/bin/uv"
```
This is laughably bad engineering. Tools should be discovered via environment variables or proper `.app` bundling, not hardcoded to the original developer's local machine path.

## 18. Terrible Asynchronous Process Killing
In `daemon.py`:
```python
def stop_daemon():
    if GoDaemon._instance:
        GoDaemon._instance.process.terminate()
```
`terminate()` sends SIGTERM. There is no waiting, no checking if the child process left zombie threads, and no cleanup of the open stdin/stdout pipes. This leaves broken pipe descriptors dangling in the OS.

## 19. No Backpressure in Stdout IPC
The entire Go-to-Python bridging relies on continuous `stdout.readline()` without any backpressure mechanics. If the Go daemon produces gigabytes of JSON fast enough, Python's `subprocess.PIPE` buffers will hit memory limits and either drop packets silently or OOM the python runner.

## 20. Code Duplication over Modularity
Instead of creating a clean unified interface for local scanning, the logic is duplicated across `Go`, `Python`, and `Rust`. There is a Go file scanner, a Python file filter, and a Rust file matcher. When a new file type (like `.mojo` or `.zig`) needs to be supported, a developer has to update 3 different regex maps in 3 different languages across 3 different processes. This is architectural insanity.


---

### Conclusion

Soma is a textbook example of "too many cooks" in terms of languages. By mixing Swift, Python, Go, and Rust, the author has created an orchestration bottleneck where serialization overhead and process spawning completely wipe out any performance gains the low-level languages theoretically provide. The architecture needs a severe consolidation and a rewrite of its IPC bridges before it can be considered robust.
