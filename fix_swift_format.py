with open('./Soma/ViewModels/SomaViewModel+Execution+Part3.swift', 'r') as f:
    content = f.read()

# Fix OneVariableDeclarationPerLine
content = content.replace("let stdout = Pipe(), stderr = Pipe()", "let stdout = Pipe()\n                        let stderr = Pipe()")

# Fix Indentation and other minor things from swift-format
# Actually, let's just run swift-format directly to fix these minor issues.
with open('./Soma/ViewModels/SomaViewModel+Execution+Part3.swift', 'w') as f:
    f.write(content)
