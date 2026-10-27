import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var m = AudioModel()
    @State private var picking = false

    private var types: [UTType] {
        [.audio] + ["flac", "alac", "m4a", "wav", "aiff"].compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    Text(m.fileName).font(.headline)
                    Text(m.fileInfo).font(.footnote.monospaced())
                    Button("Pick audio file") { picking = true }
                }
                Section("Decode") {
                    Text(m.decodeInfo).font(.footnote.monospaced())
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
                    Button("Refresh") { m.refreshInfo() }
                }
                Section("Log") {
                    ForEach(Array(m.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("Audio Test")
            .fileImporter(isPresented: $picking, allowedContentTypes: types) { result in
                switch result {
                case .success(let url): m.load(url)
                case .failure(let e): m.addLog("Picker: \(e.localizedDescription)")
                }
            }
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
