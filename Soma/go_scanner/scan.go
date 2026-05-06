package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

var (
	SkipDirs = map[string]bool{
		".git": true, ".build": true, ".idea": true, ".venv": true,
		"Assets.xcassets": true, "DerivedData": true, "Pods": true,
		"build": true, "dist": true, "node_modules": true,
		"venv": true, "xcuserdata": true, "__pycache__": true,
	}

	NoisePathNames = map[string]bool{
		".DS_Store": true,
	}

	NoiseSuffixes = map[string]bool{
		".pyc": true, ".pyo": true,
	}

	ManifestNames = map[string]bool{
		"package.json": true, "package-lock.json": true, "pnpm-lock.yaml": true,
		"yarn.lock": true, "requirements.txt": true, "requirements-dev.txt": true,
		"pyproject.toml": true, "Pipfile": true, "Pipfile.lock": true,
		"setup.py": true, "setup.cfg": true, "Package.swift": true,
		"Podfile": true, "Cartfile": true, "Gemfile": true,
		"Makefile": true, "Dockerfile": true, ".env": true,
	}

	ConfigExtensions = map[string]bool{
		".cfg": true, ".conf": true, ".ini": true, ".json": true,
		".plist": true, ".toml": true, ".xml": true, ".yaml": true, ".yml": true,
	}

	UnityExtensions = map[string]bool{
		".asmdef": true, ".asset": true, ".controller": true, ".mat": true,
		".meta": true, ".prefab": true, ".unity": true,
	}

	SourceExtensions = map[string]bool{
		".c": true, ".cc": true, ".cpp": true, ".cs": true, ".go": true,
		".h": true, ".hpp": true, ".java": true, ".js": true, ".jsx": true,
		".kt": true, ".m": true, ".mm": true, ".php": true, ".py": true,
		".rb": true, ".rs": true, ".sh": true, ".sql": true, ".swift": true,
		".ts": true, ".tsx": true, ".zsh": true,
	}

	ScriptExtensions = map[string]bool{
		".bat": true, ".command": true, ".ps1": true, ".py": true,
		".rb": true, ".sh": true, ".zsh": true,
	}

	LogExtensions = map[string]bool{
		".crash": true, ".err": true, ".log": true, ".out": true,
		".stderr": true, ".stdout": true, ".trace": true,
	}
)

const MaxDiscoveredFiles = 1500

type FileItem struct {
	Path     string  `json:"path"`
	Name     string  `json:"name"`
	Category string  `json:"category"`
	Mtime    float64 `json:"mtime"`
}

func shouldSkipDir(name string) bool {
	if SkipDirs[name] {
		return true
	}
	if strings.HasPrefix(name, ".") && name != ".config" && name != ".github" {
		return true
	}
	return false
}

func isNoisePath(path, name string) bool {
	if NoisePathNames[name] {
		return true
	}
	ext := strings.ToLower(filepath.Ext(name))
	if NoiseSuffixes[ext] {
		return true
	}
	if strings.Contains(path, "__pycache__") {
		return true
	}
	return false
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.Mode().Perm()&0111 != 0
}

func categorizePath(path, name string) string {
	ext := strings.ToLower(filepath.Ext(name))

	if ManifestNames[name] || name == "project.pbxproj" || strings.HasSuffix(name, ".xcodeproj") || strings.HasSuffix(name, ".xcworkspace") {
		return "manifest"
	}
	if UnityExtensions[ext] {
		return "unity"
	}
	nameLower := strings.ToLower(name)
	if LogExtensions[ext] || strings.Contains(nameLower, "log") || strings.HasPrefix(nameLower, "ollama_") || strings.HasPrefix(nameLower, "stderr") || strings.HasPrefix(nameLower, "stdout") {
		return "log"
	}
	if ScriptExtensions[ext] || (ext == "" && isExecutable(path)) {
		return "script"
	}
	if SourceExtensions[ext] {
		return "source"
	}
	if ConfigExtensions[ext] {
		return "config"
	}
	return ""
}

func scanFiles(root string) {
	var discovered []FileItem

	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // Skip on error
		}

		name := d.Name()
		if d.IsDir() {
			if path != root && shouldSkipDir(name) {
				return filepath.SkipDir
			}
			return nil
		}

		if d.Type()&os.ModeSymlink != 0 {
			return nil // Skip symlinks
		}

		if isNoisePath(path, name) {
			return nil
		}

		if len(discovered) >= MaxDiscoveredFiles {
			return filepath.SkipAll
		}

		category := categorizePath(path, name)
		if category != "" {
			info, err := d.Info()
			var mtime float64 = 0
			if err == nil {
				mtime = float64(info.ModTime().UnixNano()) / 1e9
			}

			if len(discovered) < MaxDiscoveredFiles {
				discovered = append(discovered, FileItem{
					Path:     path,
					Name:     name,
					Category: category,
					Mtime:    mtime,
				})
			}
		}
		return nil
	})

	if err != nil {
		fmt.Fprintf(os.Stderr, "Error walking directory: %v\n", err)
		os.Exit(1)
	}

	out, err := json.Marshal(discovered)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error marshaling JSON: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}
