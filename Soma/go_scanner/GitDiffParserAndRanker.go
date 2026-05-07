package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

type ChangedFile struct {
	Status  string `json:"status"`
	Path    string `json:"path"`
	Added   string `json:"added,omitempty"`
	Removed string `json:"removed,omitempty"`
}

type Hunk struct {
	File      string   `json:"file"`
	StartLine *int     `json:"start_line"`
	EndLine   *int     `json:"end_line"`
	Added     int      `json:"added"`
	Removed   int      `json:"removed"`
	Signals   []string `json:"signals"`
}

type GitDiffSummary struct {
	ChangedFiles        []ChangedFile `json:"changed_files"`
	ChangedFileCount    int           `json:"changed_file_count"`
	Hunks               []Hunk        `json:"hunks"`
	RawDiffCharsOmitted int           `json:"raw_diff_chars_omitted"`
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func summarizeDiffHunks(diffText string) []Hunk {
	var hunks []Hunk
	lines := strings.Split(diffText, "\n")
	var currentFile string
	var currentHunk *Hunk

	for _, line := range lines {
		if strings.HasPrefix(line, "diff --git ") {
			if idx := strings.Index(line, " b/"); idx != -1 {
				currentFile = line[idx+3:]
			} else {
				currentFile = line
			}
			currentHunk = nil
			continue
		}

		if strings.HasPrefix(line, "@@") {
			// Extract +start,length
			parts := strings.Split(line, " ")
			var startLine, length int
			startPtr := new(int)
			endPtr := new(int)
			for _, part := range parts {
				if strings.HasPrefix(part, "+") {
					nums := strings.Split(part[1:], ",")
					if len(nums) > 0 {
						if s, err := strconv.Atoi(nums[0]); err == nil {
							startLine = s
						}
					}
					if len(nums) > 1 {
						if l, err := strconv.Atoi(nums[1]); err == nil {
							length = l
						}
					} else {
						length = 1
					}
					break
				}
			}

			*startPtr = startLine
			if startLine > 0 {
				endLine := startLine + length - 1
				if endLine < startLine {
					endLine = startLine
				}
				*endPtr = endLine
			} else {
				endPtr = nil
				startPtr = nil
			}

			hunk := Hunk{
				File:      currentFile,
				StartLine: startPtr,
				EndLine:   endPtr,
				Added:     0,
				Removed:   0,
				Signals:   []string{},
			}
			hunks = append(hunks, hunk)
			currentHunk = &hunks[len(hunks)-1]
			continue
		}

		if currentHunk == nil || line == "" || strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") {
			continue
		}

		if strings.HasPrefix(line, "+") {
			currentHunk.Added++
		} else if strings.HasPrefix(line, "-") {
			currentHunk.Removed++
		}

		lowered := strings.ToLower(line)
		hasSignal := false
		signalTokens := []string{"error", "exception", "todo", "fixme", "public ", "func ", "class ", "struct ", "def "}
		for _, token := range signalTokens {
			if strings.Contains(lowered, token) {
				hasSignal = true
				break
			}
		}

		if hasSignal {
			signal := line
			if strings.HasPrefix(line, "+") || strings.HasPrefix(line, "-") {
				signal = strings.TrimSpace(line[1:])
			} else {
				signal = strings.TrimSpace(line)
			}

			if signal != "" && len(currentHunk.Signals) < 3 {
				if len(signal) > 140 {
					signal = signal[:140]
				}
				currentHunk.Signals = append(currentHunk.Signals, signal)
			}
		}
	}

	return hunks
}

func rankDiffHunks(hunks []Hunk, terms []string, maxHunks int) []Hunk {
	type ScoredHunk struct {
		hunk  Hunk
		score int
	}

	var scored []ScoredHunk

	for _, hunk := range hunks {
		score := 0
		fileName := strings.ToLower(hunk.File)
		signals := strings.ToLower(strings.Join(hunk.Signals, " "))
		haystack := fileName + " " + signals

		for _, term := range terms {
			termLower := strings.ToLower(term)
			if strings.Contains(fileName, termLower) {
				score += 20
			}
			if strings.Contains(signals, termLower) {
				score += 12
			}
		}

		if strings.HasSuffix(fileName, ".py") || strings.HasSuffix(fileName, ".swift") ||
			strings.HasSuffix(fileName, ".cs") || strings.HasSuffix(fileName, ".js") ||
			strings.HasSuffix(fileName, ".ts") {
			score += 8
		}

		fileNameTokens := []string{"relay", "scout", "pipeline", "contentview", "player", "controller"}
		for _, token := range fileNameTokens {
			if strings.Contains(fileName, token) {
				score += 8
				break
			}
		}

		haystackTokens := []string{"error", "exception", "model", "token", "prompt", "diff", "log"}
		for _, token := range haystackTokens {
			if strings.Contains(haystack, token) {
				score += 6
				break
			}
		}

		diffLines := hunk.Added + hunk.Removed
		if diffLines > 12 {
			score += 12
		} else {
			score += diffLines
		}

		scored = append(scored, ScoredHunk{hunk, score})
	}

	// Simple selection sort for descending order
	for i := 0; i < len(scored); i++ {
		for j := i + 1; j < len(scored); j++ {
			if scored[j].score > scored[i].score {
				scored[i], scored[j] = scored[j], scored[i]
			}
		}
	}

	var result []Hunk
	for i := 0; i < len(scored) && i < maxHunks; i++ {
		result = append(result, scored[i].hunk)
	}

	return result
}

func gitDiff(projectRoot string, terms []string) {
	nameStatusCmd := exec.Command("git", "diff", "HEAD", "--name-status")
	nameStatusCmd.Dir = projectRoot
	var nameStatusOut bytes.Buffer
	nameStatusCmd.Stdout = &nameStatusOut

	numstatCmd := exec.Command("git", "diff", "HEAD", "--numstat")
	numstatCmd.Dir = projectRoot
	var numstatOut bytes.Buffer
	numstatCmd.Stdout = &numstatOut

	diffCmd := exec.Command("git", "diff", "HEAD", "--unified=0", "--no-ext-diff")
	diffCmd.Dir = projectRoot
	var diffOut bytes.Buffer
	diffCmd.Stdout = &diffOut

	if err := nameStatusCmd.Run(); err != nil {
		fmt.Println("null")
		return
	}

	var changedFiles []ChangedFile
	for _, line := range strings.Split(nameStatusOut.String(), "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) >= 2 {
			path := parts[len(parts)-1]
			name := filepath.Base(path)
			if !isNoisePath(path, name) {
				changedFiles = append(changedFiles, ChangedFile{Status: parts[0], Path: path})
			}
		}
	}

	statsByPath := make(map[string]struct {
		Added   string
		Removed string
	})
	if err := numstatCmd.Run(); err == nil {
		for _, line := range strings.Split(numstatOut.String(), "\n") {
			parts := strings.Split(line, "\t")
			if len(parts) >= 3 {
				statsByPath[parts[2]] = struct {
					Added   string
					Removed string
				}{parts[0], parts[1]}
			}
		}
	}

	for i, item := range changedFiles {
		if stats, ok := statsByPath[item.Path]; ok {
			changedFiles[i].Added = stats.Added
			changedFiles[i].Removed = stats.Removed
		}
	}

	var rawDiff string
	if err := diffCmd.Run(); err == nil {
		rawDiff = diffOut.String()
	}

	allHunks := summarizeDiffHunks(rawDiff)
	var filteredHunks []Hunk
	for _, hunk := range allHunks {
		name := filepath.Base(hunk.File)
		if !isNoisePath(hunk.File, name) {
			filteredHunks = append(filteredHunks, hunk)
		}
	}

	rankedHunks := rankDiffHunks(filteredHunks, terms, 8)
	if rankedHunks == nil {
		rankedHunks = []Hunk{} // ensure non-null json array
	}

	limit := 40
	if len(changedFiles) < limit {
		limit = len(changedFiles)
	}

	var changedFilesTrim []ChangedFile = changedFiles[:limit]
	if changedFilesTrim == nil {
		changedFilesTrim = []ChangedFile{}
	}

	summary := GitDiffSummary{
		ChangedFiles:        changedFilesTrim,
		ChangedFileCount:    len(changedFiles),
		Hunks:               rankedHunks,
		RawDiffCharsOmitted: len(rawDiff),
	}

	out, err := json.Marshal(summary)
	if err != nil {
		fmt.Println("null")
		return
	}
	fmt.Println(string(out))
}
