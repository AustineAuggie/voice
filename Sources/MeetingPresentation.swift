import Foundation
#if canImport(SwiftUI) && !LOCALVOICE_MEETING_TESTING
import SwiftUI
#endif

/// Presentation derives only from saved meeting data; it never invents content.
enum MeetingPresentation {
    struct Group: Identifiable {
        var id: Date
        var title: String
        var records: [MeetingRecord]
    }
    static func groups(_ records: [MeetingRecord], now: Date = Date(), calendar: Calendar = .current) -> [Group] {
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.date) }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        return grouped.keys.sorted(by: >).map { date in
            let label: String
            if date == today { label = "TODAY" }
            else if date == yesterday { label = "YESTERDAY" }
            else { label = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased() }
            return Group(id: date, title: label, records: grouped[date, default: []].sorted { $0.date > $1.date })
        }
    }
    static func duration(_ value: Double) -> String {
        let seconds = value.isFinite ? Int(max(0, min(value, 31_536_000))) : 0
        if seconds < 60 { return "\(seconds) sec" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) hr \((seconds % 3600) / 60) min"
    }
    static func readingMinutes(_ text: String) -> Int { max(1, Int(ceil(Double(text.split(whereSeparator: \.isWhitespace).count) / 200))) }
    static func status(_ record: MeetingRecord) -> String {
        if record.summaryComplete { return "Notes ready" }
        switch record.status {
        case "recording": return "Recording"
        case "paused": return "Paused"
        case "processing": return "Processing"
        case "transcribed": return "Transcript saved"
        case "interrupted": return "Ready to recover"
        default: return "Saved on this Mac"
        }
    }
    static func overview(_ record: MeetingRecord) -> String {
        let text = (record.manualNotes ?? record.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Your overview will appear once the meeting summary is ready. Open this meeting to view its transcript or add your own notes." }
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = [], inSummary = false
        let hasSummary = lines.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "### summary" }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "### summary" { inSummary = true; continue }
            if hasSummary && inSummary && trimmed.hasPrefix("#") { break }
            if hasSummary && !inSummary { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("Source ") || trimmed.hasPrefix("Draft notes ·") { continue }
            let clean = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            result.append(clean)
            if result.count >= 3 { break }
        }
        let combined = result.joined(separator: "\n\n")
        let value = combined.isEmpty ? text : combined
        return value.count > 650 ? String(value.prefix(650)) + "…" : value
    }
    static func phase(_ value: MeetingPhase) -> String {
        switch value {
        case .idle: return "Saved"
        case .starting: return "Starting recording"
        case .recording: return "Recording"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .stopping: return "Finishing recording"
        case .transcribing: return "Transcribing"
        case .identifying: return "Identifying speakers"
        case .summarising: return "Creating notes"
        }
    }
    #if canImport(SwiftUI) && !LOCALVOICE_MEETING_TESTING
    static func speakerColor(_ id: Int?) -> Color {
        guard let id = id, id > 0 else { return VoiceTheme.muted }
        let colors: [Color] = [VoiceTheme.accent, .purple, .orange, .blue, .pink, .indigo, .cyan, .brown]
        return colors[(id - 1) % colors.count]
    }
    #endif
}

#if canImport(SwiftUI) && !LOCALVOICE_MEETING_TESTING
/// Small markdown reader for the app's saved summaries. Supporting quotations
/// stay visible, and source material is rendered as text, never executable HTML.
struct MeetingMarkdown: View {
    var text: String
    private struct Paragraph: Identifiable {
        var id: Int
        var text: String
        var kind: Kind
        enum Kind { case heading, bullet, source, paragraph }
    }
    private var paragraphs: [Paragraph] {
        text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if value.hasPrefix("#") {
                return Paragraph(id: index, text: String(value.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces), kind: .heading)
            }
            if value.hasPrefix("- ") || value.hasPrefix("* ") { return Paragraph(id: index, text: String(value.dropFirst(2)), kind: .bullet) }
            if value.hasPrefix("Source ") || value.hasPrefix("> ") {
                return Paragraph(id: index, text: value.hasPrefix("> ") ? String(value.dropFirst(2)) : value, kind: .source)
            }
            return Paragraph(id: index, text: value, kind: .paragraph)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(paragraphs) { paragraph in
                paragraphView(paragraph)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    @ViewBuilder private func paragraphView(_ paragraph: Paragraph) -> some View {
        switch paragraph.kind {
        case .heading:
            Text(paragraph.text).font(.system(size: 18, weight: .semibold)).foregroundColor(VoiceTheme.text)
                .padding(.top, 12).padding(.bottom, 3)
        case .bullet:
            HStack(alignment: .top, spacing: 11) {
                Circle().fill(VoiceTheme.accent).frame(width: 4, height: 4).padding(.top, 9)
                inline(paragraph.text).font(.system(size: 14)).lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .source:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(VoiceTheme.accent.opacity(0.25)).frame(width: 2)
                inline(paragraph.text).font(.system(size: 11)).lineSpacing(4).foregroundColor(VoiceTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).padding(.leading, 15).padding(.bottom, 5)
        case .paragraph:
            inline(paragraph.text).font(.system(size: 14)).lineSpacing(6).foregroundColor(VoiceTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func inline(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(value)
    }
}
#endif
