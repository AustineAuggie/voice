import Foundation

enum Shortcut: String, CaseIterable, Identifiable {
    case rightOption, leftOption, rightCommand, f6
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .leftOption: return "Left Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .f6: return "F6"
        }
    }
    var keyCode: Int {
        switch self {
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightCommand: return 54
        case .f6: return 97
        }
    }
    // Device-specific modifier flags distinguish the left and right keys.
    var sideMask: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .leftOption: return 0x20
        case .rightCommand: return 0x10
        case .f6: return 0
        }
    }
}

enum KeyInput: Equatable { case flags, down, up }
enum KeyAction: Equatable { case begin, finish, cancel, none }

struct HoldShortcut {
    var shortcut: Shortcut = .rightOption
    private(set) var held = false
    // Interrupted key chords stay blocked until the trigger is released.
    private var interrupted = false

    mutating func reset() { held = false; interrupted = false }

    mutating func consume(_ kind: KeyInput, code: Int, flags: UInt64, repeatKey: Bool = false) -> KeyAction {
        let isTrigger = code == shortcut.keyCode
        let isDown: Bool
        if shortcut == .f6 {
            isDown = kind == .down
            if isTrigger && kind == .flags { return .none }
        } else {
            isDown = (flags & shortcut.sideMask) != 0
            if isTrigger && kind != .flags { return .none }
        }
        if isTrigger {
            if isDown {
                guard !repeatKey, !held, !interrupted else { return .none }
                // Don't start dictation as part of another modifier chord.
                let standardModifiers: UInt64 = 0x1E0000 // shift, ctrl, option, command
                let ownModifier: UInt64 = shortcut == .rightCommand ? 0x100000 : (shortcut == .f6 ? 0 : 0x80000)
                guard (flags & standardModifiers & ~ownModifier) == 0 else {
                    interrupted = true
                    return .none
                }
                held = true
                return .begin
            }
            let wasHeld = held
            reset()
            return wasHeld ? .finish : .none
        }
        if held && (kind == .down || kind == .flags) {
            held = false
            interrupted = true
            return .cancel
        }
        return .none
    }
}

enum SpeechModel: String, CaseIterable, Identifiable {
    case largeV3, largeV3Turbo
    var id: String { rawValue }
    var label: String { self == .largeV3 ? "Best quality · Large v3" : "Faster · Large v3 Turbo" }
    var filename: String { self == .largeV3 ? "ggml-large-v3.bin" : "ggml-large-v3-turbo.bin" }
    var sizeLabel: String { self == .largeV3 ? "About 3.1 GB" : "About 1.6 GB" }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }
    // Filled from the upstream LFS metadata, not a hash of an HTML download page.
    var sha256: String {
        self == .largeV3 ? "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2" : "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    }
    var byteCount: Int64 { self == .largeV3 ? 3_095_033_483 : 1_624_555_275 }
}

enum TextRules {
    static func clean(_ raw: String, removeFillers: Bool) -> String {
        // Preserve words, numbers, repetitions, and the model's punctuation by default.
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if removeFillers {
            // Intentionally conservative. No paraphrasing or guessed self-corrections.
            text = text.replacingOccurrences(of: #"(?i)(?<![\p{L}\p{N}-])(?:um+|uh+|erm+)(?![\p{L}\p{N}-])[,;:]?\s*"#,
                                            with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
