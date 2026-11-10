import SwiftUI
import AppKit

/// Native appearance-aware colours. The warmer surfaces follow the workspace
/// reference while system appearance and text contrast remain supported.
enum VoiceTheme {
    private static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
        }))
    }
    static let canvas = adaptive((0.963, 0.957, 0.945), (0.105, 0.113, 0.113))
    static let sidebar = adaptive((0.965, 0.959, 0.948), (0.120, 0.128, 0.128))
    static let surface = adaptive((0.997, 0.995, 0.987), (0.150, 0.160, 0.160))
    static let subtle = adaptive((0.932, 0.924, 0.905), (0.205, 0.225, 0.220))
    static let border = adaptive((0.901, 0.889, 0.868), (0.260, 0.280, 0.270))
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let accent = adaptive((0.040, 0.335, 0.285), (0.380, 0.780, 0.670))
}

struct VoiceGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            configuration.label.font(.system(size: 14, weight: .semibold))
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20).background(VoiceTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(VoiceTheme.border.opacity(0.7), lineWidth: 1))
    }
}
