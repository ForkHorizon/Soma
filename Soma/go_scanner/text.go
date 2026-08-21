package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const MaxFileBytes = 160000

func readTextFile(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Sprintf("[Unable to read file: %v]", err)
	}
	defer func() { _ = file.Close() }()

	buf := make([]byte, MaxFileBytes)
	n, err := file.Read(buf)
	if err != nil && err.Error() != "EOF" {
		return fmt.Sprintf("[Unable to read file: %v]", err)
	}

	return string(buf[:n])
}

func readTextCmd(path string) (string, error) {
	return readTextFile(path), nil
}

func extractSymbols(path string, text string) []string {
	ext := strings.ToLower(filepath.Ext(path))
	var patterns []string

	switch ext {
	case ".cs":
		patterns = []string{
			`\b(?:class|struct|interface|enum)\s+([A-Za-z_][A-Za-z0-9_]*)`,
			`\b(?:public|private|protected|internal|static|virtual|override|async|\s)+\s*[A-Za-z_][A-Za-z0-9_<>,\[\]?]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(`,
		}
	case ".swift":
		patterns = []string{
			`\b(?:class|struct|enum|protocol|actor)\s+([A-Za-z_][A-Za-z0-9_]*)`,
			`\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(`,
		}
	case ".py":
		patterns = []string{
			`(?m)^\s*(?:class|def)\s+([A-Za-z_][A-Za-z0-9_]*)`,
		}
	case ".js", ".jsx", ".ts", ".tsx":
		patterns = []string{
			`\b(?:class|function)\s+([A-Za-z_][A-Za-z0-9_]*)`,
			`\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s*)?\(`,
		}
	}

	var symbols []string
	seen := make(map[string]bool)

	for _, p := range patterns {
		re, err := regexp.Compile(p)
		if err != nil {
			continue
		}

		matches := re.FindAllStringSubmatch(text, -1)
		for _, match := range matches {
			if len(match) > 1 {
				symbol := match[1]
				if !seen[symbol] {
					seen[symbol] = true
					symbols = append(symbols, symbol)
					if len(symbols) >= 12 {
						return symbols
					}
				}
			}
		}
	}
	return symbols
}

func extractUnityRefs(path string, text string) []string {
	ext := strings.ToLower(filepath.Ext(path))
	if !UnityExtensions[ext] {
		return []string{}
	}

	var refs []string
	seen := make(map[string]bool)

	if strings.Contains(text, "Missing") || strings.Contains(text, "missing") {
		refs = append(refs, "contains missing-reference text")
		seen["contains missing-reference text"] = true
	}
	if strings.Contains(text, "m_Script:") {
		refs = append(refs, "contains MonoBehaviour script reference")
		seen["contains MonoBehaviour script reference"] = true
	}

	re := regexp.MustCompile(`guid:\s*([0-9a-fA-F]{32})`)
	matches := re.FindAllStringSubmatch(text, -1)
	for _, match := range matches {
		if len(match) > 1 {
			ref := "guid:" + match[1]
			if !seen[ref] {
				seen[ref] = true
				refs = append(refs, ref)
				if len(refs) >= 12 {
					break
				}
			}
		}
	}

	return refs
}

func extractSymbolsCmd(path string) (string, error) {
	text := readTextFile(path)
	symbols := extractSymbols(path, text)
	if symbols == nil {
		symbols = []string{}
	}
	out, err := json.Marshal(symbols)
	if err == nil {
		return string(out), nil
	} else {
		return "[]", nil
	}
}

func extractUnityRefsCmd(path string) (string, error) {
	text := readTextFile(path)
	refs := extractUnityRefs(path, text)
	if refs == nil {
		refs = []string{}
	}
	out, err := json.Marshal(refs)
	if err == nil {
		return string(out), nil
	} else {
		return "[]", nil
	}
}
