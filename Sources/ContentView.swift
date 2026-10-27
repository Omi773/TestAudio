import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var m = AudioModel()
    @StateObject private var dac = DACMonitor()
    @State private var picking = false

    private var types: [UTType] {
        [.item]
    }

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    Text(m.fileName).font(.headline)
                    Text(m.fileInfo).font(.footnote.monospaced())
                }
                Section("Library") {
                    Text("Files app → On My iPhone → Audio Test → Music").font(.caption2)
                    HStack(spacing: 16) {
                        Button("Refresh library") { m.refreshLibrary() }
                        Button("Import file…") { picking = true }
                    }.buttonStyle(.bordered)
                    Text("\(m.tracks.count) track(s)").font(.footnote)
                    ForEach(m.tracks) { t in
                        Button {
                            m.load(t.url)
                            m.play()
                        } label: {
                            HStack {
                                Image(systemName: m.currentURL == t.url ? "speaker.wave.2.fill" : "music.note")
                                Text(t.rel).font(.footnote).multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
                Section("Decode · live") {
                    ForEach(m.decodeRows) { rowView($0) }
                }
                Section("Transport") {
                    Slider(value: $m.position, in: 0...max(m.duration, 1)) { editing in
                        m.isSeeking = editing
                        if !editing { m.seek(to: m.position) }
                    }
                    HStack {
                        Text(time(m.position)); Spacer(); Text(time(m.duration))
                    }.font(.footnote.monospacedDigit())
                    HStack(spacing: 24) {
                        Button(m.isPlaying ? "Pause" : "Play") { m.togglePlay() }
                        Button("Stop") { m.stop() }
                    }.buttonStyle(.bordered)
                }
                Section("Process") {
                    HStack {
                        Text(String(format: "Gain %+.1f dB", m.gainDB)).font(.footnote.monospacedDigit())
                        Spacer()
                        Button("0") { m.gainDB = 0 }
                    }
                    Slider(value: $m.gainDB, in: -24...12, step: 0.5)
                    meter("L", m.levelL)
                    meter("R", m.levelR)
                }
                Section("Output path") {
                    Text(m.pathText).font(.footnote.monospaced())
                    Text(m.sessionInfo).font(.footnote.monospaced())
                    Text(m.routeInfo).font(.footnote.monospaced())
                    ForEach(m.checks) { c in
                        Label(c.text, systemImage: c.ok ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(c.ok ? .green : .secondary)
                            .font(.footnote)
                    }
                    Button("Refresh now") { m.refreshInfo(); m.refreshDecode() }
                }
                Section("DAC · live") {
                    HStack(spacing: 8) {
                        Circle().fill(dac.connected ? Color.green : Color.red).frame(width: 10, height: 10)
                        Text(dac.headline).font(.headline)
                    }
                    if let since = dac.connectedSince {
                        HStack {
                            Text("Seen connected for").font(.caption2).foregroundStyle(.secondary)
                            Text(since, style: .timer).font(.footnote.monospacedDigit())
                        }
                    }
                    ForEach(dac.status) { rowView($0) }
                }
                Section("DAC · link & format") {
                    ForEach(dac.link) { rowView($0) }
                }
                Section("Audio session") {
                    ForEach(dac.system) { rowView($0) }
                }
                Section("DAC · supported rates") {
                    Text("Stop playback first. Requests each rate and shows what iOS grants.").font(.caption2)
                    Button(dac.probing ? "Probing…" : "Probe rates") { dac.probeRates() }
                        .buttonStyle(.bordered)
                        .disabled(dac.probing || m.isPlaying)
                    ForEach(dac.rates) { rowView($0) }
                }
                Section("DAC · events") {
                    ForEach(Array(dac.events.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
                Section("Log") {
                    ForEach(Array(m.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("Audio Test")
            .onAppear { dac.attach(engine: m.engine) }
            .fileImporter(isPresented: $picking, allowedContentTypes: types, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): m.importFiles(urls)
                case .failure(let e): m.addLog("Picker: \(e.localizedDescription)")
                }
            }
        }
    }

    private func rowView(_ r: InfoRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(r.key).font(.caption2).foregroundStyle(.secondary)
            Text(r.value).font(.footnote.monospaced())
        }
    }

    private func meter(_ label: String, _ db: Float) -> some View {
        HStack {
            Text(label).font(.footnote.monospaced())
            ProgressView(value: Double(max(db, -60) + 60), total: 60)
            Text(String(format: "%.0f dB", db)).font(.caption2.monospacedDigit()).frame(width: 52, alignment: .trailing)
        }
    }

    private func time(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}