package main

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
)

func findErrorsCmd(text string) {
	lines := strings.Split(text, "\n")
	tokens := []string{"ERROR", "EXCEPTION", "FATAL", "TRACEBACK", "CRASH"}
	var out []string

	for _, line := range lines {
		upper := strings.ToUpper(line)
		for _, token := range tokens {
			if strings.Contains(upper, token) {
				stripped := strings.TrimSpace(line)
				if len(stripped) > 5 {
					out = append(out, stripped)
				}
				break
			}
		}
	}

	if out == nil {
		out = []string{}
	}

	bytes, err := json.Marshal(out)
	if err == nil {
		fmt.Println(string(bytes))
	} else {
		fmt.Println("[]")
	}
}

func groupCompileErrorsCmd(errorsJson string) {
	var errors []string
	if err := json.Unmarshal([]byte(errorsJson), &errors); err != nil {
		fmt.Println("[]")
		return
	}

	var grouped []string
	seen := make(map[string]bool)

	re1 := regexp.MustCompile(`/[a-zA-Z0-9_./-]+:[0-9]+:[0-9]+: `)
	re2 := regexp.MustCompile(`\(at .*\)`)

	for _, errStr := range errors {
		sanitized := re1.ReplaceAllString(errStr, "")
		sanitized = re2.ReplaceAllString(sanitized, "")
		sanitized = strings.TrimSpace(sanitized)

		if !seen[sanitized] && len(sanitized) > 5 {
			seen[sanitized] = true
			grouped = append(grouped, sanitized)
		}
	}

	if grouped == nil {
		grouped = []string{}
	}

	bytes, err := json.Marshal(grouped)
	if err == nil {
		fmt.Println(string(bytes))
	} else {
		fmt.Println("[]")
	}
}

const MaxPreviewChars = 2000

func localMin(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func localMax(a, b int) int {
	if a > b {
		return a
	}
	return b
}

type ExcerptResult struct {
	Text      string `json:"text"`
	StartLine *int   `json:"start_line"`
	EndLine   *int   `json:"end_line"`
}

func excerptForTextCmd(text string, termsJson string) {
	var terms []string
	json.Unmarshal([]byte(termsJson), &terms)

	if len(text) == 0 {
		out, _ := json.Marshal(ExcerptResult{Text: ""})
		fmt.Println(string(out))
		return
	}

	lines := strings.Split(text, "\n")
	lowered := strings.ToLower(text)

	for _, term := range terms {
		idx := strings.Index(lowered, term)
		if idx != -1 {
			start := localMax(0, idx-250)
			end := localMin(len(text), idx+MaxPreviewChars)
			startLine := strings.Count(text[:start], "\n") + 1
			endLine := strings.Count(text[:end], "\n") + 1

			res := ExcerptResult{
				Text:      strings.TrimSpace(text[start:end]),
				StartLine: &startLine,
				EndLine:   &endLine,
			}
			out, _ := json.Marshal(res)
			fmt.Println(string(out))
			return
		}
	}

	previewLen := localMin(len(text), MaxPreviewChars)
	preview := strings.TrimSpace(text[:previewLen])

	startLine := 1
	var endLinePtr *int
	if len(preview) > 0 {
		endLine := localMin(len(lines), localMax(1, strings.Count(preview, "\n")+1))
		endLinePtr = &endLine
	} else {
		startLinePtr := (*int)(nil)
		out, _ := json.Marshal(ExcerptResult{Text: preview, StartLine: startLinePtr, EndLine: endLinePtr})
		fmt.Println(string(out))
		return
	}

	out, _ := json.Marshal(ExcerptResult{
		Text:      preview,
		StartLine: &startLine,
		EndLine:   endLinePtr,
	})
	fmt.Println(string(out))
}

func excerptForLogCmd(text string, termsJson string) {
	var terms []string
	json.Unmarshal([]byte(termsJson), &terms)

	lines := strings.Split(text, "\n")
	tokens := []string{"ERROR", "EXCEPTION", "FATAL", "TRACEBACK", "CRASH"}

	var errorLines []string
	for _, line := range lines {
		upper := strings.ToUpper(line)
		for _, token := range tokens {
			if strings.Contains(upper, token) {
				stripped := strings.TrimSpace(line)
				if len(stripped) > 5 {
					errorLines = append(errorLines, stripped)
				}
				break
			}
		}
	}

	if len(errorLines) > 0 {
		end := localMin(len(errorLines), 12)
		joined := strings.Join(errorLines[:end], "\n")
		textRes := joined
		if len(joined) > MaxPreviewChars {
			textRes = joined[:MaxPreviewChars]
		}
		out, _ := json.Marshal(ExcerptResult{Text: textRes})
		fmt.Println(string(out))
		return
	}

	for _, term := range terms {
		for idx, line := range lines {
			if strings.Contains(strings.ToLower(line), strings.ToLower(term)) {
				start := localMax(0, idx-8)
				end := localMin(len(lines), idx+12)
				joined := strings.Join(lines[start:end], "\n")
				textRes := joined
				if len(joined) > MaxPreviewChars {
					textRes = joined[:MaxPreviewChars]
				}
				sLine := start + 1
				eLine := end
				out, _ := json.Marshal(ExcerptResult{Text: textRes, StartLine: &sLine, EndLine: &eLine})
				fmt.Println(string(out))
				return
			}
		}
	}

	start := localMax(0, len(lines)-80)
	joined := strings.Join(lines[start:], "\n")
	textRes := joined
	if len(joined) > MaxPreviewChars {
		textRes = joined[:MaxPreviewChars]
	}

	if len(lines) > 0 {
		sLine := start + 1
		eLine := len(lines)
		out, _ := json.Marshal(ExcerptResult{Text: textRes, StartLine: &sLine, EndLine: &eLine})
		fmt.Println(string(out))
	} else {
		out, _ := json.Marshal(ExcerptResult{Text: textRes})
		fmt.Println(string(out))
	}
}
