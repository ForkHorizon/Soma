package main

import (
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <subcommand> [args...]\n", os.Args[0])
		os.Exit(1)
	}

	cmd := os.Args[1]
	switch cmd {
	case "scan-files":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s scan-files <project_root>\n", os.Args[0])
			os.Exit(1)
		}
		itemChan, errChan := scanFiles(os.Args[2])
		fmt.Print("[")
		first := true
		for item := range itemChan {
			if !first {
				fmt.Print(",")
			}
			out, _ := json.Marshal(item)
			fmt.Print(string(out))
			first = false
		}
		fmt.Println("]")
		if e := <-errChan; e != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", e)
		}
	case "git-status":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s git-status <project_root>\n", os.Args[0])
			os.Exit(1)
		}
		_, _ = gitStatus(os.Args[2])
	case "git-diff":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s git-diff <project_root> [terms...]\n", os.Args[0])
			os.Exit(1)
		}
		_, _ = gitDiff(os.Args[2], os.Args[3:])
	case "extract-symbols":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s extract-symbols <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		_, _ = extractSymbolsCmd(os.Args[2])
	case "extract-unity-refs":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s extract-unity-refs <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		_, _ = extractUnityRefsCmd(os.Args[2])
	case "read-text":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s read-text <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		_, _ = readTextCmd(os.Args[2])
	case "tail-logs":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s tail-logs <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		_, _ = tailLogsCmd(os.Args[2])
	case "find-errors":
		if len(os.Args) < 3 {
			os.Exit(1)
		}
		_, _ = findErrorsCmd(os.Args[2])
	case "group-compile-errors":
		if len(os.Args) < 3 {
			os.Exit(1)
		}
		_, _ = groupCompileErrorsCmd(os.Args[2])
	case "excerpt-for-text":
		if len(os.Args) < 4 {
			os.Exit(1)
		}
		_, _ = excerptForTextCmd(os.Args[2], os.Args[3])
	case "excerpt-for-log":
		if len(os.Args) < 4 {
			os.Exit(1)
		}
		_, _ = excerptForLogCmd(os.Args[2], os.Args[3])
	case "daemon":
		runDaemon()
	default:
		fmt.Fprintf(os.Stderr, "Unknown subcommand: %s\n", cmd)
		os.Exit(1)
	}
}
