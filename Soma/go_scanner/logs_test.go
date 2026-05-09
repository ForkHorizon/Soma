package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMatchToken(t *testing.T) {
	tests := []struct {
		input  string
		token  string
		expect bool
	}{
		{"ERROR", "ERROR", true},
		{"error", "ERROR", true},
		{"eRrOr", "ERROR", true},
		{"ERROR: foo", "ERROR", true},
		{"ERR", "ERROR", false},
	}

	for _, tc := range tests {
		result := matchToken([]byte(tc.input), tc.token)
		if result != tc.expect {
			t.Errorf("matchToken(%q, %q) = %v, want %v", tc.input, tc.token, result, tc.expect)
		}
	}
}

func TestContainsToken(t *testing.T) {
	tests := []struct {
		input  string
		expect bool
	}{
		{"This is an ERROR", true},
		{"An exception occurred", true},
		{"FaTaL crash", true},
		{"Traceback (most recent call last):", true},
		{"CRASH in module", true},
		{"Normal log line", false},
		{"Error_like", true},
		{"E", false},
	}

	for _, tc := range tests {
		result := containsToken([]byte(tc.input))
		if result != tc.expect {
			t.Errorf("containsToken(%q) = %v, want %v", tc.input, result, tc.expect)
		}
	}
}

func TestTailLogs(t *testing.T) {
	content := `Normal line
This is an ERROR line
Another exception
Just a short CRASH
Fatal issue
Not bad
`
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "test.log")
	if err := os.WriteFile(logPath, []byte(content), 0644); err != nil {
		t.Fatalf("Failed to create test log file: %v", err)
	}

	errors := tailLogs(logPath)
	if len(errors) != 4 {
		t.Errorf("tailLogs() returned %d errors, want 4. Errors: %v", len(errors), errors)
	}

	expected := []string{
		"This is an ERROR line",
		"Another exception",
		"Just a short CRASH",
		"Fatal issue",
	}

	for i, exp := range expected {
		if errors[i] != exp {
			t.Errorf("Error %d mismatch: got %q, want %q", i, errors[i], exp)
		}
	}
}
