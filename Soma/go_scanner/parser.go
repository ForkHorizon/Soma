package main

import (
	"encoding/json"
	"regexp"
	"strings"
)

func findErrorsCmd(text string) (string, error) {
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
		return string(bytes), nil
	} else {
		return "[]", nil
	}
}

func groupCompileErrorsCmd(errorsJson string) (string, error) {
	var errors []string
	if err := json.Unmarshal([]byte(errorsJson), &errors); err != nil {
		return "[]", nil
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
		return string(bytes), nil
	} else {
		return "[]", nil
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

func excerptForTextCmd(text string, termsJson string) (string, error) {
	var terms []string
	json.Unmarshal([]byte(termsJson), &terms)

	if len(text) == 0 {
		out, _ := json.Marshal(ExcerptResult{Text: ""})
		return string(out), nil
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
			return string(out), nil
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
		return string(out), nil
	}

	out, _ := json.Marshal(ExcerptResult{
		Text:      preview,
		StartLine: &startLine,
		EndLine:   endLinePtr,
	})
	return string(out), nil
}

func excerptForLogCmd(text string, termsJson string) (string, error) {
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
		return string(out), nil
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
				return string(out), nil
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
		return string(out), nil
	} else {
		out, _ := json.Marshal(ExcerptResult{Text: textRes})
		return string(out), nil
	}
}
