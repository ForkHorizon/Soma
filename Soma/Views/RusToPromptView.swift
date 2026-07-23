import SwiftUI

enum RusToPromptOutputTab: String, CaseIterable, Identifiable {
    case improved = "Improved"
    case translation = "Translation"
    case confidence = "Confidence"
    var id: String { rawValue }
}

struct RusToPromptView: View {
    @ObservedObject var viewModel: RusToPromptViewModel
    @ObservedObject var somaViewModel: SomaViewModel
    @ObservedObject var ollama: OllamaManager
    @ObservedObject var queueManager: RusToPromptQueueManager
    @State var selectedOutput: RusToPromptOutputTab = .improved
    @State var showModels = false
    @State var copied = false
    @State var modelStats: TestModelStatsEnvelope?
    @State var isLoadingModelStats = false
    @State var modelStatsStatus = "Stats not loaded"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    inputPane
                        .frame(minWidth: 360)
                    outputPane
                        .frame(minWidth: 360)
                }

                VStack(alignment: .leading, spacing: 14) {
                    inputPane
                    outputPane
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        }
        .background(SomaDesign.pageBackground)
        .onAppear {
            ollama.refreshInstalledModels()
            ollama.checkStatus()
            loadRusToPromptModelStatsIfNeeded()
        }
    }

}
