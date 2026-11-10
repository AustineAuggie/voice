import SwiftUI
import AppKit

final class MeetingPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MeetingPromptHostingView: NSHostingView<MeetingPromptView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A suggestion only. Detection never starts microphone or system capture.
struct MeetingPromptView: View {
    var appName: String
    var start: () -> Void
    var options: () -> Void
    var dismiss: () -> Void
    var disable: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meeting detected").font(.system(size: 18, weight: .medium)).foregroundColor(.white)
                    HStack(spacing: 6) {
                        Circle().fill(Color(red: 0.16, green: 0.76, blue: 0.55)).frame(width: 6, height: 6)
                        Text("\(appName) · Now").font(.system(size: 11)).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    Button(action: start) {
                        HStack(spacing: 9) {
                            Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white).frame(width: 27, height: 29)
                                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 7))
                            Text("Start Notetaker").font(.system(size: 13, weight: .semibold)).foregroundColor(Color(white: 0.12))
                        }.padding(.leading, 11).padding(.trailing, 12).frame(height: 49).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Starts recording microphone and Mac audio for this meeting")
                    Rectangle().fill(Color.black.opacity(0.15)).frame(width: 1, height: 31)
                    Menu {
                        Button("Meeting options…", action: options)
                        Button("Dismiss", action: dismiss)
                        Divider()
                        Button("Turn off meeting prompts", action: disable)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(white: 0.15)).frame(width: 29, height: 49)
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Meeting prompt options")
                }.background(Color(red: 0.995, green: 0.995, blue: 0.935), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.leading, 22).padding(.trailing, 17).padding(.vertical, 19)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 1))
            .padding(.top, 10).padding(.leading, 10)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundColor(.white.opacity(0.75))
                    .frame(width: 25, height: 25).background(Color(white: 0.17), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Dismiss meeting suggestion").accessibilityLabel("Dismiss meeting suggestion")
        }.padding(5).frame(width: 510, height: 110)
    }
}
