package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

func tailLogs(path string) []string {
	file, err := os.Open(path)
	if err != nil {
		return []string{}
	}
	defer file.Close()

	var errors []string
	tokens := []string{"ERROR", "EXCEPTION", "FATAL", "TRACEBACK", "CRASH"}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		upper := strings.ToUpper(line)
		for _, token := range tokens {
			if strings.Contains(upper, token) {
				stripped := strings.TrimSpace(line)
				if len(stripped) > 5 {
					errors = append(errors, stripped)
					// Avoid storing too many errors in memory
					if len(errors) >= 1000 {
						return errors
					}
				}
				break
			}
		}
	}

	if err := scanner.Err(); err != nil {
		// Log parsing error
	}

	return errors
}

func tailLogsCmd(path string) {
	errors := tailLogs(path)
	out, err := json.Marshal(errors)
	if err == nil {
		fmt.Println(string(out))
	} else {
		fmt.Println("[]")
	}
}
