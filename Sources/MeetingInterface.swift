import SwiftUI
import AppKit

struct MeetingsView: View {
    @ObservedObject var meetings: MeetingState
    @ObservedObject var dictation: AppState
    var body: some View {
        GeometryReader { geometry in
            Group {
                if meetings.showingMeetingDetail, let record = meetings.selected { detail(record) }
                else { library(width: geometry.size.width) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(VoiceTheme.canvas)
        }
        .sheet(isPresented: $meetings.showNewMeeting) { newMeeting }
        .alert("Delete this meeting?", isPresented: $meetings.showDeleteConfirmation) {
            Button("Cancel", role: .cancel, action: meetings.cancelDeletion)
            Button("Delete", role: .destructive, action: meetings.confirmDeletion)
        } message: { Text("This removes its notes, transcript and retained audio from this Mac.") }
    }

    private func library(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            libraryHeader
            if meetings.busy { activeMeeting.padding(.horizontal, 30).padding(.bottom, 18) }
            if meetings.records.isEmpty { emptyLibrary }
            else {
                HStack(spacing: 0) {
                    libraryList
                    if width >= 750 {
                        Rectangle().fill(VoiceTheme.border).frame(width: 1)
                        preview.frame(width: min(294, width * 0.33))
                    }
                }
            }
            statusFooter
        }
    }
    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notetaker").font(.system(size: 29, weight: .semibold))
                    Text("Every conversation, a little clearer.").font(.system(size: 13)).foregroundColor(VoiceTheme.muted)
                }
                Spacer(minLength: 12)
                Button { meetings.showNewMeeting = true } label: {
                    Label("Start meeting", systemImage: "record.circle").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).tint(VoiceTheme.accent).disabled(meetings.busy || dictation.busy)
            }
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic").font(.system(size: 18)).foregroundColor(VoiceTheme.accent)
                    .frame(width: 38, height: 38).background(VoiceTheme.accent.opacity(0.07), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text("A nudge when your meeting starts").font(.system(size: 13, weight: .medium))
                    Text("Voice can detect a call and ask if you want to take notes.").font(.system(size: 12)).foregroundColor(VoiceTheme.muted)
                }
                Spacer(minLength: 10)
                Toggle("Suggest meeting notes", isOn: $meetings.autoDetect).labelsHidden().toggleStyle(.switch)
                    .help("Recording always requires Start. Start in-room meetings manually.")
            }.padding(15).background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(VoiceTheme.border, lineWidth: 1))
        }.padding(.horizontal, 30).padding(.top, 29).padding(.bottom, 22)
    }
    private var emptyLibrary: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 10)
            Image(systemName: "waveform").font(.system(size: 31, weight: .light)).foregroundColor(VoiceTheme.accent)
                .frame(width: 82, height: 82).background(VoiceTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 25))
            VStack(spacing: 10) {
                Text("Be present. Keep the details.").font(.system(size: 29, weight: .regular, design: .serif))
                Text("Turn your next conversation into a transcript,\nclear notes and next steps. All on your Mac.")
                    .font(.system(size: 14)).foregroundColor(VoiceTheme.muted).multilineTextAlignment(.center).lineSpacing(5)
            }
            Button { meetings.showNewMeeting = true } label: {
                Label("Take your first meeting notes", systemImage: "plus").padding(.horizontal, 9).padding(.vertical, 5)
            }.buttonStyle(.borderedProminent).tint(VoiceTheme.accent).disabled(meetings.busy || dictation.busy)
            HStack(spacing: 8) {
                sourceChip("Zoom / Meet / Teams", symbol: "video")
                sourceChip("In the room", symbol: "person.2")
            }.padding(.top, 4)
            Spacer(minLength: 25)
            Label("Your meetings stay on this Mac", systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundColor(VoiceTheme.muted).padding(.bottom, 30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 25)
    }
    private func sourceChip(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
            .padding(.horizontal, 10).padding(.vertical, 7).background(VoiceTheme.subtle, in: Capsule())
    }
    private var libraryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Past notes").font(.system(size: 14, weight: .semibold))
                Text("\(meetings.records.count)").font(.system(size: 11, weight: .medium)).foregroundColor(VoiceTheme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(VoiceTheme.subtle, in: Capsule())
                Spacer()
            }.padding(.horizontal, 30).padding(.top, 7).padding(.bottom, 15)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(VoiceTheme.muted)
                TextField("Search meeting notes", text: $meetings.query).textFieldStyle(.plain)
                if !meetings.query.isEmpty {
                    Button { meetings.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(VoiceTheme.muted) }
                        .buttonStyle(.plain).help("Clear search")
                }
            }.font(.system(size: 12)).padding(11).background(VoiceTheme.subtle, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 30).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if meetings.filtered.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "magnifyingglass").font(.title2)
                            Text("No matching meetings").font(.headline)
                            Text("Try another name or phrase.").font(.callout)
                        }.foregroundColor(VoiceTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 65)
                    } else {
                        ForEach(MeetingPresentation.groups(meetings.filtered)) { group in
                            Text(group.title).font(.system(size: 10, weight: .semibold)).tracking(1.3)
                                .foregroundColor(VoiceTheme.muted).padding(.top, 22).padding(.bottom, 6).padding(.horizontal, 12)
                            ForEach(group.records) { record in meetingRow(record) }
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 24)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private func meetingRow(_ record: MeetingRecord) -> some View {
        HStack(spacing: 11) {
            Button { meetings.select(record) } label: {
                HStack(spacing: 11) {
                    Image(systemName: record.source == .online ? "video" : "person.2")
                        .font(.system(size: 16)).foregroundColor(meetings.selection == record.id ? VoiceTheme.accent : VoiceTheme.muted)
                        .frame(width: 39, height: 43).background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title).font(.system(size: 13, weight: .medium)).foregroundColor(VoiceTheme.text).lineLimit(2)
                        Text("\(record.date.formatted(date: .omitted, time: .shortened)) · \(MeetingPresentation.duration(record.duration))")
                            .font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                    }
                    Spacer(minLength: 1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Preview this meeting")
            Button { meetings.openMeeting(record) } label: { Image(systemName: "arrow.up.right").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundColor(VoiceTheme.muted).padding(7).help("Open meeting notes")
        }.padding(12).background(meetings.selection == record.id ? VoiceTheme.subtle : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .contextMenu {
                Button("Open meeting") { meetings.openMeeting(record) }
                Button("Delete meeting…", role: .destructive) { meetings.requestDeletion(record) }.disabled(meetings.busy)
            }
    }
    private var preview: some View {
        Group {
            if let record = meetings.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(record.title).font(.system(size: 21, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundColor(VoiceTheme.muted)
                            Text(MeetingPresentation.status(record)).font(.system(size: 10, weight: .medium)).foregroundColor(VoiceTheme.accent)
                                .padding(.horizontal, 8).padding(.vertical, 5).background(VoiceTheme.accent.opacity(0.07), in: Capsule())
                        }
                        Rectangle().fill(VoiceTheme.border).frame(height: 1)
                        VStack(alignment: .leading, spacing: 13) {
                            eyebrow("Overview")
                            Text(MeetingPresentation.overview(record)).font(.system(size: 13)).lineSpacing(6)
                                .foregroundColor(VoiceTheme.text).textSelection(.enabled)
                        }
                        if !record.speakerIDs.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                eyebrow("Speakers")
                                ForEach(Array(record.speakerIDs.prefix(8)), id: \.self) { id in
                                    HStack(spacing: 8) {
                                        Circle().fill(MeetingPresentation.speakerColor(id)).frame(width: 7, height: 7)
                                        Text(record.speakerLabel(id)).font(.system(size: 12)).lineLimit(1)
                                    }
                                }
                                if record.speakerIDs.count > 8 { Text("+ \(record.speakerIDs.count - 8) more").font(.caption).foregroundColor(VoiceTheme.muted) }
                            }
                        }
                        Button { meetings.openMeeting(record) } label: {
                            HStack { Text("Open meeting notes"); Spacer(); Image(systemName: "arrow.up.right") }
                                .font(.system(size: 12, weight: .medium)).padding(5)
                        }.buttonStyle(.bordered).controlSize(.large)
                    }.padding(24)
                }.background(VoiceTheme.surface.opacity(0.55))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text").font(.system(size: 24, weight: .light))
                    Text("A little context, at a glance.").font(.system(size: 13, weight: .medium))
                    Text("Select a meeting to preview its notes.").font(.system(size: 12)).multilineTextAlignment(.center)
                }.foregroundColor(VoiceTheme.muted).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detail(_ record: MeetingRecord) -> some View {
        VStack(spacing: 0) {
            detailToolbar(record)
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(record.title).font(.system(size: 34, weight: .regular, design: .serif)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        HStack(spacing: 13) {
                            Label(record.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            Label(MeetingPresentation.duration(record.duration), systemImage: "clock")
                            Label(record.source == .online ? "Online meeting" : "In the room", systemImage: record.source == .online ? "video" : "person.2")
                        }.font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                    }.padding(.top, 14)
                    if meetings.busy { activeMeeting }
                    if !record.notice.isEmpty { notice(record.notice) }
                    detailTabs
                    Group {
                        if meetings.detailTab == 0 { personalNotes }
                        else if meetings.detailTab == 1 { transcript(record) }
                        else { summary(record) }
                    }
                }.frame(maxWidth: 810, alignment: .leading).padding(.horizontal, 34).padding(.bottom, 45)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            statusFooter
        }
    }
    private func detailToolbar(_ record: MeetingRecord) -> some View {
        HStack(spacing: 10) {
            Button(action: meetings.backToMeetings) { Label("All meetings", systemImage: "chevron.left").font(.system(size: 12, weight: .medium)) }
                .buttonStyle(.plain).foregroundColor(VoiceTheme.muted).padding(9)
            Spacer()
            Button(action: meetings.copySelected) { Label("Copy", systemImage: "doc.on.doc") }
            Button(action: meetings.exportSelected) { Label("Export", systemImage: "square.and.arrow.up") }
            Menu {
                if !record.summaryComplete || (record.speakersEnabled == true && record.speakersComplete != true) {
                    Button("Recover / retry") { meetings.retry(record) }.disabled(meetings.busy)
                }
                if meetings.selectedSpeakerDiagnostics != nil {
                    Button("Copy speaker diagnostics") { meetings.copySpeakerDiagnostics() }.disabled(meetings.busy)
                }
                Button("Delete meeting…", role: .destructive) { meetings.requestDeletion(record) }.disabled(meetings.busy)
            } label: { Image(systemName: "ellipsis").font(.system(size: 17)).frame(width: 22) }
                .menuStyle(.borderlessButton).fixedSize().help("Meeting actions")
        }.controlSize(.regular).padding(.horizontal, 27).padding(.top, 20).padding(.bottom, 8)
    }
    private var detailTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 27) {
                detailTab("My notes", icon: "square.and.pencil", value: 0)
                detailTab("Transcript", icon: "text.alignleft", value: 1)
                detailTab("Summary", icon: "sparkles", value: 2)
                Spacer(minLength: 0)
            }
            Rectangle().fill(VoiceTheme.border).frame(height: 1)
        }
    }
    private func detailTab(_ label: String, icon: String, value: Int) -> some View {
        Button { meetings.detailTab = value } label: {
            VStack(spacing: 13) {
                Label(label, systemImage: icon).font(.system(size: 13, weight: meetings.detailTab == value ? .semibold : .regular))
                    .foregroundColor(meetings.detailTab == value ? VoiceTheme.text : VoiceTheme.muted)
                Rectangle().fill(meetings.detailTab == value ? VoiceTheme.text : Color.clear).frame(height: 2)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain)
    }
    private var personalNotes: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your own thoughts").font(.system(size: 18, weight: .semibold))
                    Text("Keep your observations alongside the meeting. These stay separate from the generated summary.")
                        .font(.system(size: 12)).foregroundColor(VoiceTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 15)
                Button("Save notes", action: meetings.savePersonalNotes).buttonStyle(.borderedProminent)
                    .disabled(meetings.busy || !meetings.hasUnsavedPersonalNotes)
            }
            TextEditor(text: $meetings.personalNotesDraft).font(.system(size: 14)).lineSpacing(5)
                .scrollContentBackground(.hidden).padding(14).frame(minHeight: 330)
                .background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(VoiceTheme.border, lineWidth: 1)).disabled(meetings.busy)
            Text(meetings.hasUnsavedPersonalNotes ? "Unsaved changes" : "Saved on this Mac")
                .font(.system(size: 11)).foregroundColor(meetings.hasUnsavedPersonalNotes ? .orange : VoiceTheme.muted)
            if meetings.busy { Text("You can add your own notes once recording and processing finish.").font(.caption).foregroundColor(VoiceTheme.muted) }
        }
    }
    private func summary(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "text.book.closed")
                    Text((record.manualNotes ?? record.notes).isEmpty ? "SUMMARY" : "\(MeetingPresentation.readingMinutes(record.manualNotes ?? record.notes)) MIN READ").tracking(1)
                }.font(.system(size: 10, weight: .medium)).foregroundColor(VoiceTheme.muted)
                Spacer()
                if meetings.editingSummary {
                    Text(meetings.hasUnsavedSummary ? "Unsaved changes" : "Saved").font(.caption).foregroundColor(VoiceTheme.muted)
                    Button("Save summary", action: meetings.saveNotes).disabled(meetings.busy)
                    Button("Done") { if meetings.saveSelectedDrafts() { meetings.editingSummary = false } }.disabled(meetings.busy)
                } else {
                    Button { meetings.editingSummary = true } label: { Label("Edit summary", systemImage: "square.and.pencil") }.disabled(meetings.busy)
                }
            }.padding(14).background(VoiceTheme.subtle, in: RoundedRectangle(cornerRadius: 11))
            if meetings.editingSummary {
                TextEditor(text: $meetings.notesDraft).font(.system(size: 14)).lineSpacing(5)
                    .scrollContentBackground(.hidden).padding(14).frame(minHeight: 400)
                    .background(VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(VoiceTheme.border, lineWidth: 1)).disabled(meetings.busy)
            } else if (record.manualNotes ?? record.notes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 22)).foregroundColor(VoiceTheme.accent)
                    Text(meetings.busy ? "Your summary is on its way." : "Your transcript is saved.").font(.system(size: 20, weight: .regular, design: .serif))
                    Text(meetings.busy ? "Voice creates the summary when the meeting has finished processing." : "Create or recover the summary from the meeting’s saved transcript.")
                        .font(.system(size: 13)).foregroundColor(VoiceTheme.muted)
                    if !meetings.busy { Button("Recover / retry") { meetings.retry(record) }.buttonStyle(.bordered) }
                }.padding(.vertical, 28)
            } else { MeetingMarkdown(text: record.manualNotes ?? record.notes) }
            if !record.summaryComplete && !meetings.busy && !(record.manualNotes ?? record.notes).isEmpty {
                Button("Recover incomplete summary") { meetings.retry(record) }.buttonStyle(.bordered)
            }
        }
    }
    private func transcript(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Approximate timestamps", systemImage: "clock").font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                Spacer()
                if !record.speakerIDs.isEmpty { Text("\(record.speakerIDs.count) speaker labels").font(.system(size: 11)).foregroundColor(VoiceTheme.muted) }
            }
            if let status = record.speakerStatus, !status.isEmpty { Text(status).font(.system(size: 12)).foregroundColor(VoiceTheme.muted) }
            if let turns = record.speakerTurns, !turns.isEmpty {
                DisclosureGroup("Manage speakers") { speakerControls(record).padding(.top, 15) }
                    .font(.system(size: 13, weight: .medium)).padding(16).background(VoiceTheme.subtle, in: RoundedRectangle(cornerRadius: 12))
                speakerTranscript(record, turns: turns)
            } else {
                Text(record.transcript.isEmpty ? "The transcript will appear here as your meeting audio is processed." : record.transcript)
                    .font(.system(size: 14)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Labels are estimates. Rename a speaker or correct a passage when needed. Changes update the transcript; written summaries stay unchanged.")
                .font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
        }
    }
    private func speakerControls(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if !record.speakerIDs.isEmpty {
                HStack {
                    Picker("Rename", selection: $meetings.speakerToRename) {
                        ForEach(record.speakerIDs, id: \.self) { id in Text(record.speakerLabel(id)).tag(id) }
                    }.frame(maxWidth: 230).onChange(of: meetings.speakerToRename) { id in meetings.beginSpeakerRename(id) }
                    TextField("Speaker name", text: $meetings.speakerNameDraft).textFieldStyle(.roundedBorder)
                    Button("Apply name", action: meetings.renameSelectedSpeaker)
                }
                HStack {
                    Picker("Combine with", selection: $meetings.speakerMergeTarget) {
                        Text("Choose speaker").tag(0)
                        ForEach(record.speakerIDs.filter { $0 != meetings.speakerToRename }, id: \.self) { id in Text(record.speakerLabel(id)).tag(id) }
                    }.frame(maxWidth: 300)
                    Button("Combine labels", action: meetings.mergeSelectedSpeaker).disabled(meetings.speakerMergeTarget == 0)
                    Spacer(minLength: 0)
                }
                Text("Combine two labels when they are the same person. Clear a name to return to its numbered label.").font(.caption).foregroundColor(VoiceTheme.muted)
            } else { Text("Use a passage’s menu to add a speaker label.").foregroundColor(VoiceTheme.muted) }
        }.font(.system(size: 12)).disabled(meetings.busy)
    }
    private func speakerTranscript(_ record: MeetingRecord, turns: [SpeakerTurn]) -> some View {
        let pageCount = max(1, (turns.count + 39) / 40)
        let page = min(max(0, meetings.speakerPage), pageCount - 1)
        return VStack(alignment: .leading, spacing: 23) {
            ForEach(Array(turns.dropFirst(page * 40).prefix(40))) { turn in speakerPassage(turn, record: record) }
            if pageCount > 1 {
                HStack {
                    Button("Previous") { meetings.speakerPage = page - 1 }.disabled(page == 0)
                    Spacer()
                    Text("\(page + 1) / \(pageCount)").font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                    Spacer()
                    Button("Next") { meetings.speakerPage = page + 1 }.disabled(page + 1 >= pageCount)
                }.padding(.top, 8)
            }
        }
    }
    private func speakerPassage(_ turn: SpeakerTurn, record: MeetingRecord) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(turn.speaker.map { String($0) } ?? "?").font(.system(size: 12, weight: .semibold))
                .foregroundColor(MeetingPresentation.speakerColor(turn.speaker))
                .frame(width: 31, height: 31).background(MeetingPresentation.speakerColor(turn.speaker).opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(record.speakerLabel(turn.speaker)).font(.system(size: 12, weight: .semibold)).foregroundColor(MeetingPresentation.speakerColor(turn.speaker))
                    Text(MeetingText.time(turn.start)).font(.system(size: 10).monospacedDigit()).foregroundColor(VoiceTheme.muted)
                    Spacer()
                    Menu {
                        Button("Unclear speaker") { meetings.assignSpeaker(turnID: turn.id, speaker: nil) }
                        ForEach(record.speakerIDs, id: \.self) { id in Button(record.speakerLabel(id)) { meetings.assignSpeaker(turnID: turn.id, speaker: id) } }
                        Divider()
                        Button("New speaker") { meetings.assignNewSpeaker(turnID: turn.id) }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 18) }
                        .menuStyle(.borderlessButton).fixedSize().disabled(meetings.busy).help("Correct this speaker")
                }
                Text(turn.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activeMeeting: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle().fill(meetings.phase == .recording ? Color.red : VoiceTheme.accent).frame(width: 7, height: 7)
                Text(MeetingPresentation.phase(meetings.phase)).font(.system(size: 12, weight: .semibold))
                Text(MeetingText.time(meetings.elapsed)).font(.system(size: 12).monospacedDigit()).foregroundColor(VoiceTheme.muted)
                Spacer(minLength: 12)
                captureActions
            }
            if meetings.phase == .recording {
                HStack(spacing: 22) {
                    meter("Microphone", value: meetings.microphoneLevel, icon: "mic")
                    if meetings.source == .online { meter("Mac audio", value: meetings.computerLevel, icon: "speaker.wave.2") }
                }
            }
            Text(meetings.phase == .recording ? "Recording on this Mac. Check that the meters move when people speak." : "Your captured audio and completed transcript are saved as processing continues.")
                .font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
        }.padding(16).background(VoiceTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(VoiceTheme.accent.opacity(0.16), lineWidth: 1))
    }
    @ViewBuilder private var captureActions: some View {
        if meetings.phase == .recording {
            Button("Pause", action: meetings.pause)
            Button("Finish meeting", action: meetings.stop).buttonStyle(.borderedProminent).tint(VoiceTheme.accent)
        } else if meetings.phase == .paused {
            Button("Resume", action: meetings.resume)
            Button("Finish meeting", action: meetings.stop).buttonStyle(.borderedProminent).tint(VoiceTheme.accent)
        } else if [.transcribing, .identifying, .summarising].contains(meetings.phase) {
            ProgressView().controlSize(.small)
            Button("Stop processing", action: meetings.stopProcessing).help("Keeps this meeting for recovery")
        } else {
            ProgressView().controlSize(.small)
            if meetings.phase == .starting { Button("Cancel", action: meetings.cancelStart) }
        }
    }
    private func meter(_ label: String, value: Float, icon: String) -> some View {
        HStack(spacing: 9) {
            Label(label, systemImage: icon).font(.system(size: 10)).foregroundColor(VoiceTheme.muted)
            ProgressView(value: Double(value)).tint(VoiceTheme.accent).frame(maxWidth: 140)
        }
    }
    private var newMeeting: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Start a meeting").font(.system(size: 28, weight: .regular, design: .serif))
                    Text("Voice takes care of the details, locally.").font(.system(size: 13)).foregroundColor(VoiceTheme.muted)
                }
                Spacer()
                Button { meetings.showNewMeeting = false } label: { Image(systemName: "xmark").frame(width: 19, height: 19) }
                    .buttonStyle(.plain).foregroundColor(VoiceTheme.muted).help("Close")
            }.padding(25)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        eyebrow("Meeting title")
                        TextField("What are you meeting about? (optional)", text: $meetings.title).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        eyebrow("Where is the conversation?")
                        HStack(spacing: 12) {
                            sourceOption(.online, title: "Online meeting", subtitle: "Mac audio + microphone", icon: "video")
                            sourceOption(.room, title: "In the room", subtitle: "Your Mac’s microphone", icon: "person.2")
                        }
                        Text(meetings.source == .online ? "Use headphones. Voice captures all Mac audio, including other tabs; pause unrelated audio before starting." : "Place your Mac where every participant can be heard. Speaker labels work best when people take turns.")
                            .font(.system(size: 11)).foregroundColor(VoiceTheme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 15) {
                        Toggle("Identify speakers automatically", isOn: $meetings.identifySpeakers).toggleStyle(.switch)
                        Text("Estimates distinct voices after you finish. Labels can be renamed or corrected.").font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                        Toggle("Keep audio after processing", isOn: $meetings.keepAudio).toggleStyle(.switch)
                        Text("Otherwise, audio is removed after successful transcription and speaker analysis. Saved notes stay on this Mac.").font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                    }.font(.system(size: 13))
                    Text("Let participants know before starting. Online meetings may ask for Screen & System Audio Recording permission; no screen video is saved.")
                        .font(.system(size: 11)).foregroundColor(VoiceTheme.muted).fixedSize(horizontal: false, vertical: true)
                    if !meetings.message.isEmpty { Text(meetings.message).font(.system(size: 11)).foregroundColor(VoiceTheme.muted).lineLimit(3) }
                }.padding(25)
            }
            Divider()
            HStack {
                Label("Only on your Mac", systemImage: "lock.shield").font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
                Spacer()
                Button("Cancel") { meetings.showNewMeeting = false }.keyboardShortcut(.cancelAction)
                Button("Start recording") {
                    meetings.start(model: dictation.model, language: dictation.language, vocabulary: DictationText.preferredWords(dictation.vocabulary))
                }.buttonStyle(.borderedProminent).tint(VoiceTheme.accent).keyboardShortcut(.defaultAction).disabled(meetings.busy || dictation.busy)
            }.padding(25)
        }.frame(width: 535, height: 600).background(VoiceTheme.canvas).foregroundColor(VoiceTheme.text)
    }
    private func sourceOption(_ value: MeetingSource, title: String, subtitle: String, icon: String) -> some View {
        Button { meetings.source = value } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack { Image(systemName: icon); Spacer(); if meetings.source == value { Image(systemName: "checkmark.circle.fill") } }
                    .font(.system(size: 16)).foregroundColor(meetings.source == value ? VoiceTheme.accent : VoiceTheme.muted)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(VoiceTheme.text)
                Text(subtitle).font(.system(size: 11)).foregroundColor(VoiceTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
                .background(meetings.source == value ? VoiceTheme.accent.opacity(0.06) : VoiceTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(meetings.source == value ? VoiceTheme.accent.opacity(0.5) : VoiceTheme.border, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundColor(VoiceTheme.muted)
    }
    private func notice(_ text: String) -> some View {
        Label { Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
            .foregroundColor(VoiceTheme.muted).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(VoiceTheme.subtle, in: RoundedRectangle(cornerRadius: 12))
    }
    private var statusFooter: some View {
        HStack(spacing: 8) {
            Circle().fill(VoiceTheme.accent).frame(width: 5, height: 5)
            Text(meetings.message).font(.system(size: 10)).foregroundColor(VoiceTheme.muted).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 10)
        }.padding(.horizontal, 30).padding(.vertical, 11).background(VoiceTheme.canvas)
    }
}

struct MeetingPill: View {
    @ObservedObject var meetings: MeetingState
    var body: some View {
        HStack(spacing: 8) {
            Button { meetings.reveal?() } label: {
                HStack(spacing: 7) {
                    Image(systemName: meetings.phase == .recording ? "record.circle.fill" : meetings.phase == .paused ? "pause.circle" : "text.alignleft")
                        .foregroundColor(meetings.phase == .recording ? .red : .mint)
                    Text(meetings.phase == .recording ? MeetingText.time(meetings.elapsed) : meetings.phase == .paused ? "Paused" : "Meeting notes")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }.buttonStyle(.plain)
            if meetings.phase == .recording { Button(action: meetings.pause) { Image(systemName: "pause.fill") }.buttonStyle(.plain).help("Pause meeting recording") }
            if meetings.phase == .paused { Button(action: meetings.resume) { Image(systemName: "play.fill") }.buttonStyle(.plain).help("Resume meeting recording") }
        }.frame(width: 150, height: 38).background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.2))).padding(6)
    }
}
