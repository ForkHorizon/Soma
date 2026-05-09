## 2024-05-24 - O(1) direct file checks for project detection
**Learning:** Using `os.listdir()` to find file markers enumerates the entire directory into memory, burning CPU and memory if a root folder contains massive build outputs or poorly structured files.
**Action:** Replaced `os.listdir()` with `os.path.exists()` for direct O(1) checks and used a short-circuiting `os.scandir()` for wildcard matches to maximize performance.
