import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var testCasesPanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Input scenarios")
                        .font(.headline)
                    StatusChip(text: "\(caseCount) cases", tone: caseCount > 0 ? .info : .warning)
                }
                Text(casesURL.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Menu {
                    if caseFiles.isEmpty {
                        Text("No test files")
                    } else {
                        ForEach(caseFiles, id: \.path) { file in
                            Button {
                                selectCasesFile(file)
                            } label: {
                                HStack {
                                    if file.lastPathComponent == selectedCasesFileName {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(file.lastPathComponent)
                                }
                            }
                        }
                    }
                } label: {
                    Label("File", systemImage: "doc.text")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

                HStack(spacing: 6) {
                    Button {
                        createEmptyCasesFile()
                    } label: {
                        Label("New", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Create an empty test file")

                    Button {
                        deleteSelectedCasesFile()
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: casesURL.path))
                    .help("Remove the selected test file")
                }
            }
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }


    func modelSelectionPanel(
        title: String,
        icon: String,
        role: TestModelRole,
        knownPresets: [RusToPromptModelPreset],
        selection: Binding<Set<String>>,
        storageKey: String,
        isPresented: Binding<Bool>,
        sort: Binding<TestModelSort>,
        customModel: Binding<String>
    ) -> some View {
        let rows = rankedModelPresets(role: role, knownPresets: knownPresets, sort: sort.wrappedValue, extraModels: selection.wrappedValue)

        return VStack(alignment: .leading, spacing: 8) {
            modelSelectionHeader(title: title, icon: icon, selection: selection)
            modelSelectionButton(
                title: title,
                rows: rows,
                selection: selection,
                storageKey: storageKey,
                isPresented: isPresented,
                sort: sort,
                customModel: customModel
            )
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }


    func modelSelectionHeader(title: String, icon: String, selection: Binding<Set<String>>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(selectedModelsSummary(selection.wrappedValue))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusChip(text: "\(selection.wrappedValue.count) selected", tone: selection.wrappedValue.isEmpty ? .warning : .info)
        }
    }


    func modelSelectionButton(
        title: String,
        rows: [TestRankedModelPreset],
        selection: Binding<Set<String>>,
        storageKey: String,
        isPresented: Binding<Bool>,
        sort: Binding<TestModelSort>,
        customModel: Binding<String>
    ) -> some View {
        Button {
            if !isPresented.wrappedValue {
                loadModelStatsIfNeeded()
            }
            isPresented.wrappedValue.toggle()
        } label: {
            HStack {
                Text("Choose models")
                Spacer()
                Image(systemName: isPresented.wrappedValue ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: isPresented, arrowEdge: .bottom) {
            modelSelectionPopover(
                title: title,
                rows: rows,
                selection: selection,
                storageKey: storageKey,
                sort: sort,
                customModel: customModel
            )
        }
        .disabled(rows.isEmpty)
    }


    func modelSelectionPopover(
        title: String,
        rows: [TestRankedModelPreset],
        selection: Binding<Set<String>>,
        storageKey: String,
        sort: Binding<TestModelSort>,
        customModel: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            modelPopoverHeader(title: title, selection: selection)
            modelSortPicker(sort)
            customModelEntry(customModel, selection: selection, storageKey: storageKey)
            modelRowsList(rows, selection: selection, storageKey: storageKey)
        }
        .padding(12)
        .frame(width: 540)
    }


    func modelPopoverHeader(title: String, selection: Binding<Set<String>>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
            StatusChip(text: "\(selection.wrappedValue.count) selected", tone: selection.wrappedValue.isEmpty ? .warning : .info)
            Spacer()
            if isLoadingModelStats {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                ollama.refreshInstalledModels()
                loadModelStats()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }


    func modelSortPicker(_ sort: Binding<TestModelSort>) -> some View {
        Picker("Sort", selection: sort) {
            ForEach(TestModelSort.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }


    func customModelEntry(
        _ customModel: Binding<String>,
        selection: Binding<Set<String>>,
        storageKey: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField("Custom model, e.g. deepseek-v4-flash, gemini-3-pro-preview, or gpt-5.5", text: customModel)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            Button {
                addCustomModel(customModel, selection: selection, storageKey: storageKey)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(customModel.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .help("Add any model name supported by Ollama, Codex CLI, Gemini CLI, or DeepSeek API. Names starting with gpt-/o-/codex- run via Codex; gemini-/auto-gemini run via Gemini; deepseek- runs via DeepSeek.")
    }


    @ViewBuilder
    func modelRowsList(
        _ rows: [TestRankedModelPreset],
        selection: Binding<Set<String>>,
        storageKey: String
    ) -> some View {
        if rows.isEmpty {
            Text(ollama.isOllamaRunning ? "No installed Ollama models returned." : "Start Ollama to list installed models.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        modelToggleRow(row, selection: selection, storageKey: storageKey)
                    }
                }
            }
            .frame(maxHeight: 340)
        }
    }

}
