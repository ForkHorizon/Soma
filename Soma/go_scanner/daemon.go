package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
)

type DaemonRequest struct {
	ID     string   `json:"id"`
	Method string   `json:"method"`
	Args   []string `json:"args"`
}

type DaemonResponse struct {
	ID    string `json:"id"`
	Error string `json:"error,omitempty"`
	Data  string `json:"data,omitempty"`
}

func sendResponse(resp DaemonResponse) {
	out, err := json.Marshal(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error marshaling response: %v\n", err)
		return
	}
	fmt.Println(string(out))
}

func getScanFilesOutput(root string) (string, error) {
	// Re-implementing scanFiles locally to return string instead of printing
	// This is slightly tricky, we will capture stdout locally if possible,
	// or refactor the commands. For now, let's refactor the commands to return strings
	// if we can, or just intercept stdout.
	return "", nil
}

func runDaemon() {
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		line := scanner.Text()
		var req DaemonRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			sendResponse(DaemonResponse{Error: fmt.Sprintf("invalid json: %v", err)})
			continue
		}

		var result string
		var err error

		// To capture stdout safely, we pipe os.Stdout and start reading from it immediately
		rescueStdout := os.Stdout
		r, w, _ := os.Pipe()
		os.Stdout = w

		done := make(chan []byte)
		go func() {
			var buf []byte
			temp := make([]byte, 4096)
			for {
				n, errRead := r.Read(temp)
				if n > 0 {
					buf = append(buf, temp[:n]...)
				}
				if errRead != nil {
					break
				}
			}
			done <- buf
		}()

		switch req.Method {
		case "scan-files":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				scanFiles(req.Args[0])
			}
		case "git-status":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				gitStatus(req.Args[0])
			}
		case "git-diff":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				gitDiff(req.Args[0], req.Args[1:])
			}
		case "extract-symbols":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				extractSymbolsCmd(req.Args[0])
			}
		case "extract-unity-refs":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				extractUnityRefsCmd(req.Args[0])
			}
		case "read-text":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				readTextCmd(req.Args[0])
			}
		case "tail-logs":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				tailLogsCmd(req.Args[0])
			}
		case "find-errors":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				findErrorsCmd(req.Args[0])
			}
		case "group-compile-errors":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				groupCompileErrorsCmd(req.Args[0])
			}
		case "excerpt-for-text":
			if len(req.Args) < 2 {
				err = fmt.Errorf("missing argument")
			} else {
				excerptForTextCmd(req.Args[0], req.Args[1])
			}
		case "excerpt-for-log":
			if len(req.Args) < 2 {
				err = fmt.Errorf("missing argument")
			} else {
				excerptForLogCmd(req.Args[0], req.Args[1])
			}
		default:
			err = fmt.Errorf("unknown method: %s", req.Method)
		}

		w.Close()
		output := <-done
		os.Stdout = rescueStdout
		r.Close()

		if err == nil {
			result = string(output)
		}

		if err != nil {
			sendResponse(DaemonResponse{ID: req.ID, Error: err.Error()})
		} else {
			sendResponse(DaemonResponse{ID: req.ID, Data: result})
		}
	}
}
