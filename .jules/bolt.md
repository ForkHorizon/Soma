## 2024-05-24 - Avoid `pathlib.Path` instantiation in hot paths
**Learning:** Instantiating `pathlib.Path` objects and calling their methods (like `resolve()` or `relative_to()`) is significantly slower than using the equivalent string-based operations in `os.path`. In this codebase's architecture, operations like `normalize_path`, `rel_path`, and `detect_project_type` are called very frequently. A simple benchmark showed `os.path.relpath` is nearly 3x faster than `Path.relative_to`, and `os.listdir` is over 10x faster than `Path.iterdir()` for simple string matching.
**Action:** When performing path normalization, relative path calculations, or fast directory scanning, prefer `os.path.realpath`, `os.path.relpath`, and `os.listdir` combined with standard string methods (like `endswith()`) instead of `pathlib.Path` object instantiation, especially inside mapping or reduction loops.
## 2026-05-09 - Eliminate redundant os.stat file system round-trips
**Learning:** File metadata gathered efficiently during Go's directory walk was previously discarded, forcing Python to perform redundant `os.stat` calls and doubling file system round trips during repo indexing.
**Action:** Propagated `Size` and `MtimeNs` from Go's `os.FileInfo` into the JSON IPC payload, allowing Python to construct cache identifiers without accessing the disk again.
## 2025-05-09 - Stream Go logger JSON serialization to avoid memory spikes
**Learning:** Reading massive log files into a string slice array and marshaling the entire slice as a single JSON blob results in huge memory spikes for large files.
**Action:** Stream serialization to stdout by iterating the log lines and individually marshaling elements directly (`fmt.Print("[")`, `fmt.Print(string(marshaled_element))`, `fmt.Println("]")`), significantly reducing memory footprints.
## 2024-05-24 - O(1) direct file checks for project detection
**Learning:** Using `os.listdir()` to find file markers enumerates the entire directory into memory, burning CPU and memory if a root folder contains massive build outputs or poorly structured files.
**Action:** Replaced `os.listdir()` with `os.path.exists()` for direct O(1) checks and used a short-circuiting `os.scandir()` for wildcard matches to maximize performance.
