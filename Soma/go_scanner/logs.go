package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// matchToken performs a case-insensitive check to see if b starts with the given uppercase token.
func matchToken(b []byte, token string) bool {
	if len(b) < len(token) {
		return false
	}
	for i := 0; i < len(token); i++ {
		c := b[i]
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		if c != token[i] {
			return false
		}
	}
	return true
}

// containsToken performs a fast, allocation-free check for specific error tokens.
func containsToken(b []byte) bool {
	for i := 0; i < len(b); i++ {
		c := b[i]
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		switch c {
		case 'E':
			if matchToken(b[i:], "ERROR") || matchToken(b[i:], "EXCEPTION") {
				return true
			}
		case 'F':
			if matchToken(b[i:], "FATAL") {
				return true
			}
		case 'T':
			if matchToken(b[i:], "TRACEBACK") {
				return true
			}
		case 'C':
			if matchToken(b[i:], "CRASH") {
				return true
			}
		}
	}
	return false
}

func tailLogs(path string) []string {
	file, err := os.Open(path)
	if err != nil {
		fmt.Println("[]")
		return nil
	}
	defer file.Close()

	var errors []string

	fmt.Print("[")
	_ = true
	count := 0

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		// Use scanner.Bytes() to avoid allocation.
		b := scanner.Bytes()
		if containsToken(b) {
			// Allocate a string only when we find an error token.
			line := string(b)
			stripped := strings.TrimSpace(line)
			if len(stripped) > 5 {
				errors = append(errors, stripped)
				// Avoid storing too many errors in memory
				if len(errors) >= 1000 {
					return errors
				}
			}
		}
		// Limit to 1000 results even while streaming, to avoid unlimited output
		if count >= 1000 {
			break
		}
	}

	if err := scanner.Err(); err != nil {
		// Log parsing error
	}

	return errors
}

func tailLogsCmd(path string) (string, error) {
	errors := tailLogs(path)
	out, err := json.Marshal(errors)
	if err == nil {
		return string(out), nil
	} else {
		return "[]", nil
	}
}
