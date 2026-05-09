package main

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
)

// tailLogsCmd reads log files and uses streaming serialization to avoid memory spikes.
// Instead of buffering thousands of error lines in memory (which was causing massive memory
// usage for large log files), it streams the JSON array elements directly to stdout.
func tailLogsCmd(path string) {
	file, err := os.Open(path)
	if err != nil {
		fmt.Println("[]")
		return
	}
	defer file.Close()

	tokens := []string{"ERROR", "EXCEPTION", "FATAL", "TRACEBACK", "CRASH"}

	fmt.Print("[")
	first := true
	count := 0

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		upper := strings.ToUpper(line)
		for _, token := range tokens {
			if strings.Contains(upper, token) {
				stripped := strings.TrimSpace(line)
				if len(stripped) > 5 {
					if !first {
						fmt.Print(",")
					}
					out, _ := json.Marshal(stripped)
					fmt.Print(string(out))
					first = false
					count++
				}
				break
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

	fmt.Println("]")
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
