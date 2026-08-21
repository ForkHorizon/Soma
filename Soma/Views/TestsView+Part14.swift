import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func saveLocalConfidenceModels() {
        if let data = try? JSONEncoder().encode(selectedLocalConfidenceModels) {
            UserDefaults.standard.set(data, forKey: localConfidenceModelsKey)
        }
    }

    func saveHybridConfidence(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hybridConfidenceKey)
    }

    func toggleLocalConfidenceModel(_ model: String) {
        if let index = selectedLocalConfidenceModels.firstIndex(of: model) {
            selectedLocalConfidenceModels.remove(at: index)
        } else {
            if selectedLocalConfidenceModels.count >= 2 {
                selectedLocalConfidenceModels.removeFirst()
            }
            selectedLocalConfidenceModels.append(model)
        }
        saveLocalConfidenceModels()
    }

    func saveConfidenceBatchSize(_ size: Int) {
        UserDefaults.standard.set(size, forKey: confidenceBatchSizeKey)
    }

    func saveBenchmarkMode(_ mode: TestBenchmarkMode) {
        UserDefaults.standard.set(mode.cliValue, forKey: benchmarkModeKey)
    }

    func refreshCaseFiles() {
        try? FileManager.default.createDirectory(at: casesDirectoryURL, withIntermediateDirectories: true)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: casesDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        caseFiles =
            files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
    }

    func migrateLegacyCaseFilesIfNeeded() {
        let fileManager = FileManager.default
        let scriptsURL = casesDirectoryURL.deletingLastPathComponent()
        guard
            let legacyFiles = try? fileManager.contentsOfDirectory(
                at: scriptsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        do {
            try fileManager.createDirectory(at: casesDirectoryURL, withIntermediateDirectories: true)
            for legacyFile in legacyFiles where legacyFile.pathExtension.lowercased() == "txt" {
                let proposedDestination = casesDirectoryURL.appendingPathComponent(legacyFile.lastPathComponent)
                let destination = uniqueCaseFileURL(for: proposedDestination)
                try fileManager.moveItem(at: legacyFile, to: destination)
            }
        } catch {
            statusText = "Could not migrate test files: \(error.localizedDescription)"
        }
    }

    func uniqueCaseFileURL(for url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return url
        }

        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for index in 1...999 {
            let candidateName = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
    }

    func loadSelectedCasesFile() {
        let stored = UserDefaults.standard.string(forKey: casesFileKey)
        if let stored,
            caseFiles.contains(where: { $0.lastPathComponent == stored })
        {
            selectedCasesFileName = stored
            return
        }

        if caseFiles.contains(where: { $0.lastPathComponent == selectedCasesFileName }) {
            UserDefaults.standard.set(selectedCasesFileName, forKey: casesFileKey)
            return
        }

        if let first = caseFiles.first {
            selectedCasesFileName = first.lastPathComponent
            UserDefaults.standard.set(selectedCasesFileName, forKey: casesFileKey)
            return
        }

        createEmptyCasesFile(named: "rus_to_prompt_cases.txt", selectAfterCreate: true)
    }

    func selectCasesFile(_ file: URL) {
        selectedCasesFileName = file.lastPathComponent
        UserDefaults.standard.set(selectedCasesFileName, forKey: casesFileKey)
        loadCases()
    }

    func createEmptyCasesFile() {
        createEmptyCasesFile(named: nextEmptyCasesFileName(), selectAfterCreate: true)
    }

    func createEmptyCasesFile(named fileName: String, selectAfterCreate: Bool) {
        do {
            try FileManager.default.createDirectory(at: casesDirectoryURL, withIntermediateDirectories: true)
            let newFile = casesDirectoryURL.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: newFile.path) {
                try starterCasesTemplate.write(to: newFile, atomically: true, encoding: .utf8)
            }
            refreshCaseFiles()
            if selectAfterCreate {
                selectCasesFile(newFile)
                statusText = "Created \(newFile.lastPathComponent)"
            }
        } catch {
            statusText = "Could not create test file: \(error.localizedDescription)"
        }
    }

    var starterCasesTemplate: String {
        """
        # Rus to Prompt test scenarios
        #
        # Add one scenario per block. Use this structure:
        #
        # ### rtp-001 [category-name]
        # Paste the Russian or mixed-language prompt here.
        #
        # Notes:
        # - Remove "# " from the example lines when adding real scenarios.
        # - Keep code blocks, inline code, JSON, URLs, file paths, and commands exactly as input.
        # - Separate scenarios with a blank line.

        """
    }

    func nextEmptyCasesFileName() -> String {
        let existing = Set(caseFiles.map(\.lastPathComponent))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamped = "rus_to_prompt_cases_\(formatter.string(from: Date())).txt"
        if !existing.contains(timestamped) {
            return timestamped
        }

        for index in 1...999 {
            let candidate = "rus_to_prompt_cases_\(index).txt"
            if !existing.contains(candidate) {
                return candidate
            }
        }
        return "rus_to_prompt_cases_new.txt"
    }

    func deleteSelectedCasesFile() {
        let file = casesURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            statusText = "Selected test file does not exist"
            refreshCaseFiles()
            loadSelectedCasesFile()
            loadCases()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Delete \(file.lastPathComponent)?"
        alert.informativeText = "This removes the selected test scenarios file from Scripts/rus_to_prompt_tests."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try FileManager.default.removeItem(at: file)
            refreshCaseFiles()
            if let next = caseFiles.first {
                selectCasesFile(next)
                statusText = "Deleted \(file.lastPathComponent)"
            } else {
                createEmptyCasesFile(named: "rus_to_prompt_cases.txt", selectAfterCreate: true)
                statusText = "Deleted \(file.lastPathComponent); created empty rus_to_prompt_cases.txt"
            }
        } catch {
            statusText = "Could not delete \(file.lastPathComponent): \(error.localizedDescription)"
        }
    }

}
