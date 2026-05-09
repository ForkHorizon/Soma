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

		switch req.Method {
		case "scan-files":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = scanFiles(req.Args[0])
			}
		case "git-status":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = gitStatus(req.Args[0])
			}
		case "git-diff":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = gitDiff(req.Args[0], req.Args[1:])
			}
		case "extract-symbols":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = extractSymbolsCmd(req.Args[0])
			}
		case "extract-unity-refs":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = extractUnityRefsCmd(req.Args[0])
			}
		case "read-text":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = readTextCmd(req.Args[0])
			}
		case "tail-logs":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = tailLogsCmd(req.Args[0])
			}
		case "find-errors":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = findErrorsCmd(req.Args[0])
			}
		case "group-compile-errors":
			if len(req.Args) < 1 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = groupCompileErrorsCmd(req.Args[0])
			}
		case "excerpt-for-text":
			if len(req.Args) < 2 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = excerptForTextCmd(req.Args[0], req.Args[1])
			}
		case "excerpt-for-log":
			if len(req.Args) < 2 {
				err = fmt.Errorf("missing argument")
			} else {
				result, err = excerptForLogCmd(req.Args[0], req.Args[1])
			}
		default:
			err = fmt.Errorf("unknown method: %s", req.Method)
		}

		if err != nil {
			sendResponse(DaemonResponse{ID: req.ID, Error: err.Error()})
		} else {
			sendResponse(DaemonResponse{ID: req.ID, Data: result})
		}
	}
}
