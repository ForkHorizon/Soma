package main

import (
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
		scanFiles(os.Args[2])
	case "git-status":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s git-status <project_root>\n", os.Args[0])
			os.Exit(1)
		}
		gitStatus(os.Args[2])
	case "git-diff":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s git-diff <project_root> [terms...]\n", os.Args[0])
			os.Exit(1)
		}
		gitDiff(os.Args[2], os.Args[3:])
	case "extract-symbols":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s extract-symbols <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		extractSymbolsCmd(os.Args[2])
	case "extract-unity-refs":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s extract-unity-refs <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		extractUnityRefsCmd(os.Args[2])
	case "read-text":
		if len(os.Args) < 3 {
			fmt.Fprintf(os.Stderr, "Usage: %s read-text <file_path>\n", os.Args[0])
			os.Exit(1)
		}
		readTextCmd(os.Args[2])
	default:
		fmt.Fprintf(os.Stderr, "Unknown subcommand: %s\n", cmd)
		os.Exit(1)
	}
}
