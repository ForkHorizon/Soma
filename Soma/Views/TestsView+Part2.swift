import SwiftUI
import AppKit
import Foundation

extension TestsView {
    var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Tests", systemImage: "testtube.2")
                .font(.title3.weight(.semibold))
                .foregroundColor(.primary)

            HStack(spacing: 10) {
                Button {
                    showQueue = true
                } label: {
                    Label("Queue", systemImage: "tray.full")
                    StatusChip(text: queueManager.statusBadgeText, tone: queueStatusTone)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    showModelStats = true
                } label: {
                    Label("Model Stats", systemImage: "chart.bar.xaxis")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openStressLogsFolder()
                } label: {
                    Label("Open Logs", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the .stress logs folder in Finder")

                Button {
                    loadCases()
                    loadLastResultsIfAvailable()
                    ollama.refreshInstalledModels()
                    ollama.checkStatus()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    openCasesInVSCode()
                } label: {
                    Label("VSCode", systemImage: "curlybraces.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }


    var queueSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Label("Real Prompt Queue", systemImage: "tray.full")
                        .font(.title3.weight(.semibold))
                    StatusChip(text: queueManager.statusBadgeText, tone: queueStatusTone)
                    StatusChip(text: queueManager.powerSource.label, tone: queuePowerTone)
                    StatusChip(text: "\(queueManager.completedCount) done", tone: .good)
                    if queueManager.failedCount > 0 {
                        StatusChip(text: "\(queueManager.failedCount) needs attention", tone: .warning)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: queueManager.queueDirectoryPath))
                    } label: {
                        Label("Open Queue Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        openStressLogsFolder()
                    } label: {
                        Label("Open Logs", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    if mode == .full {
                        Button {
                            showQueue = false
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .help("Close queue")
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    queueSettingsPanel
                        .frame(width: 330, alignment: .topLeading)
                    queueItemsPanel
                        .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
                    queueActivePanel
                        .frame(width: 300, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    queueSettingsPanel
                    queueItemsPanel
                    queueActivePanel
                }
            }
        }
        .padding(18)
        .background(SomaDesign.pageBackground)
    }


    var queueSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)

            Toggle("Auto benchmark real prompts", isOn: Binding(
                get: { queueManager.settings.autoEnqueueEnabled },
                set: { queueManager.setAutoEnqueueEnabled($0) }
            ))
            .toggleStyle(.switch)

            HStack {
                Text("Power")
                    .foregroundColor(.secondary)
                Spacer()
                StatusChip(text: queueManager.powerSource.label, tone: queuePowerTone)
            }
            .font(.caption)
            .help("Automatic queue starts wait for adapter power. Manual Start, Resume, and Run Now can override battery mode for the current run.")

            queueCandidatePanel(
                title: "Translators",
                role: .translator,
                selected: queueManager.settings.translatorCandidates,
                update: queueManager.updateTranslatorCandidates
            )

            queueCandidatePanel(
                title: "Improvers",
                role: .improver,
                selected: queueManager.settings.improverCandidates,
                update: queueManager.updateImproverCandidates
            )

            queueConfidencePanel

            Stepper(value: Binding(
                get: { Int(queueManager.settings.cooldownSeconds) },
                set: { queueManager.updateCooldown(seconds: Double($0)) }
            ), in: 0...600, step: 5) {
                Text("Cooldown \(Int(queueManager.settings.cooldownSeconds))s")
            }

            Stepper(value: Binding(
                get: { Int(queueManager.settings.ramWarningGB) },
                set: { queueManager.updateRAMWarning(gb: Double($0)) }
            ), in: 0...64, step: 1) {
                Text("RAM warning \(Int(queueManager.settings.ramWarningGB)) GB")
            }

            HStack {
                Text("Free RAM")
                    .foregroundColor(.secondary)
                Spacer()
                let free = queueManager.freeMemoryGB
                StatusChip(
                    text: free.map { String(format: "%.1f GB", $0) } ?? "Unknown",
                    tone: (free ?? 999) < queueManager.settings.ramWarningGB ? .warning : .good
                )
                Button {
                    queueManager.refreshFreeMemory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(12)
        .background(SomaDesign.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.12)))
    }

}
