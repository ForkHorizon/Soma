import Foundation

struct Layer1ModelSpec: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let family: String
    let optional: Bool
    var identifiable: String { id }

    var configuration: [String: String] {
        ["model": id, "family": family, "audio_scope": "full_original", "language": "ru"]
    }

    static let catalog: [Layer1ModelSpec] = [
        .init(
            id: "whisper-large-v3-mlx", title: "Whisper large-v3 (MLX)", family: "Whisper",
            optional: false),
        .init(id: "gigaam-v2-rnnt", title: "GigaAM v2 RNNT", family: "GigaAM", optional: false),
        .init(id: "gigaam-v2-ctc", title: "GigaAM v2 CTC", family: "GigaAM", optional: false),
        .init(id: "gigaam-v3-rnnt", title: "GigaAM v3 RNNT", family: "GigaAM", optional: false),
        .init(id: "gigaam-v3-e2e-ctc", title: "GigaAM v3 e2e-CTC", family: "GigaAM", optional: false),
        .init(id: "parakeet-tdt-v3", title: "Parakeet-TDT-v3", family: "Parakeet", optional: false),
        .init(id: "qwen3-asr-1.7b", title: "Qwen3-ASR-1.7B", family: "Qwen", optional: false),
        .init(id: "vosk-small-ru", title: "Vosk small-ru", family: "Vosk", optional: false),
        .init(id: "wav2vec2-xls-r-ru", title: "wav2vec2 XLS-R ru", family: "wav2vec2", optional: false),
        .init(id: "mms-1b-rus", title: "MMS-1B rus", family: "MMS", optional: false),
        .init(id: "faster-whisper", title: "faster-whisper", family: "Whisper", optional: false),
        .init(
            id: "gigaam-multilingual", title: "GigaAM-Multilingual", family: "GigaAM", optional: true),
    ]
}

struct Layer1AudioCandidate: Hashable {
    let url: URL
    let date: Date
    let duration: Double
}
