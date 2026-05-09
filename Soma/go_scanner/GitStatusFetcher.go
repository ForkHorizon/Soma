package main

import (
	"bytes"
	"os/exec"
	"path/filepath"
	"strings"
)

func gitStatus(projectRoot string) (string, error) {
	cmd := exec.Command("git", "status", "--short", "--branch")
	cmd.Dir = projectRoot
	var out bytes.Buffer
	cmd.Stdout = &out

	if err := cmd.Run(); err != nil {
		return "", nil
	}

	lines := strings.Split(out.String(), "\n")
	var resultLines []string

	for _, line := range lines {
		if strings.HasPrefix(line, "## ") {
			resultLines = append(resultLines, line)
			continue
		}

		path := line
		if len(line) > 3 {
			path = strings.TrimSpace(line[3:])
		} else {
			path = strings.TrimSpace(line)
		}

		if idx := strings.Index(path, " -> "); idx != -1 {
			path = path[idx+4:]
		}

		if path == "" {
			continue
		}

		name := filepath.Base(path)
		if isNoisePath(path, name) {
			continue
		}
		resultLines = append(resultLines, line)
	}

	status := strings.TrimSpace(strings.Join(resultLines, "\n"))
	if status != "" {
		return status, nil
	} else {
		return "Clean (No changes detected)", nil
	}
}
