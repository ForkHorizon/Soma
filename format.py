import re

def reformat_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Apply 4-space indentation and clean up lines
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        if line.startswith("static func executeProcess") or line.startswith("func runScript") or line.startswith("nonisolated func pythonPath") or line.startswith("func scriptEnvironment"):
            new_lines.append(line.rstrip())
        elif line.strip() == "":
            new_lines.append("")
        else:
            new_lines.append(line.rstrip())

    # We will manually replace the exact string that needs reformatting
    with open(filepath, 'w') as f:
        f.write('\n'.join(new_lines))

# The actual issue is method length > 50 lines.
# We need to extract part of `executePythonTool` in `SomaMCPCoordinator.swift`
# and `executeProcess` in `SomaViewModel+Execution+Part3.swift` into separate helper methods.
