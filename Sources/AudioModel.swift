import AVFoundation
import Combine
import UIKit

struct Track: Identifiable, Hashable {
    let url: URL
    let rel: String
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct Check: Identifiable, Equatable {
    let text: String
    let ok: Bool
    var id: String { text }
}

final class AudioModel: ObservableObject {
    @Published var fileName = "No file loaded"
    @Published var fileInfo = "-"
    @Published var decodeInfo = "-"
    @Published var decodeRows: [InfoRow] = []
    @Published var pathText = "-"
    @Published var sessionInfo = "-"
    @Published var routeInfo = "-"
    @Published var checks: [Check] = []
    @Published var isPlaying = false
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var levelL: Float = -90
    @Published var levelR: Float = -90
    @Published var log: [String] = []
    @Published var tracks: [Track] = []
    @Published var currentURL: URL?
    @Published var gainDB: Float = 0 {
        didSet {
            eq.globalGain = gainDB
            eq.bypass = (gainDB == 0)
            refreshInfo()
        }
    }

    var isSeeking = false

    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private var file: AVAudioFile?
    private var codecText = "-"
    private var bitsText = "n/a"
    private var startFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var scopedURL: URL?
    private var timer: Timer?
    private var tickCount = 0
    private var fileBytes: Int64 = 0
    private var peakL: Float = -90
    private var peakR: Float = -90
    private var clips = 0

    init() {
        engine.attach(player)
        engine.attach(eq)
        eq.bypass = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            self?.addLog("Route change (reason \(reason))")
            self?.refreshInfo()
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.addLog("Engine config changed")
            self?.recover()
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            self?.addLog("Interruption \(t == 1 ? "began" : "ended")")
            if t == 1 { self?.player.pause(); self?.isPlaying = false }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLibrary()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        refreshLibrary()
    }

    // MARK: Library (Documents folder, visible in Files > On My iPhone > Audio Test)

    private var docsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func refreshLibrary() {
        let fm = FileManager.default
        let docs = docsURL
        try? fm.createDirectory(at: docs.appendingPathComponent("Music"), withIntermediateDirectories: true)
        let exts: Set<String> = ["flac", "m4a", "alac", "wav", "aiff", "aif", "mp3", "caf", "aac"]
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [Track] = []
            let base = docs.resolvingSymlinksInPath().path
            if let en = fm.enumerator(at: docs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let u as URL in en where exts.contains(u.pathExtension.lowercased()) {
                    var rel = u.resolvingSymlinksInPath().path
                    if rel.hasPrefix(base + "/") { rel = String(rel.dropFirst(base.count + 1)) }
                    found.append(Track(url: u, rel: rel))
                }
            }
            found.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }
            DispatchQueue.main.async {
                self.tracks = found
                self.addLog("Library refreshed: \(found.count) track(s)")
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        let fm = FileManager.default
        let dir = docsURL.appendingPathComponent("Music")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var last: URL?
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: u, to: dest)
                last = dest
                addLog("Imported \(u.lastPathComponent)")
            } catch {
                addLog("Import failed: \(error.localizedDescription)")
            }
        }
        refreshLibrary()
        if let l = last { load(l) }
    }

    func play() { if !isPlaying { togglePlay() } }

    // MARK: Load / decode

    func load(_ url: URL) {
        player.stop()
        isPlaying = false
        generation += 1
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            let ff = f.fileFormat, pf = f.processingFormat
            let asbd = ff.streamDescription.pointee
            codecText = fourCC(asbd.mFormatID)
            bitsText = detectBits(url: url, asbd: asbd)
            fileName = url.lastPathComponent
            fileBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            peakL = -90; peakR = -90; clips = 0
            currentURL = url
            duration = Double(f.length) / pf.sampleRate
            position = 0
            fileInfo = "\(codecText) · \(Int(ff.sampleRate)) Hz · \(bitsText) bit · \(ff.channelCount) ch · \(f.length) frames"
            decodeInfo = "AVAudioFile → \(pf.commonFormat == .pcmFormatFloat32 ? "Float32" : "PCM") \(Int(pf.sampleRate)) Hz · \(pf.channelCount) ch · \(pf.isInterleaved ? "interleaved" : "planar")"
            try configureSession(rate: ff.sampleRate)
            try connectGraph(format: pf)
            installMeter()
            prepare(from: 0)
            refreshInfo()
            refreshDecode()
            addLog("Loaded \(url.lastPathComponent)")
        } catch {
            addLog("Load failed: \(error.localizedDescription)")
        }
    }

    private func configureSession(rate: Double) throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playback, mode: .default, options: [])
        try s.setPreferredSampleRate(rate)
        try s.setActive(true)
    }

    private func connectGraph(format: AVAudioFormat) throws {
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(eq)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        let out = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: out)
        engine.prepare()
        try engine.start()
    }

    private func recover() {
        guard let f = file else { return }
        let wasPlaying = isPlaying
        let frame = AVAudioFramePosition(position * f.processingFormat.sampleRate)
        do {
            try configureSession(rate: f.fileFormat.sampleRate)
            try connectGraph(format: f.processingFormat)
            installMeter()
            prepare(from: frame)
            if wasPlaying { player.play(); isPlaying = true }
        } catch { addLog("Recover failed: \(error.localizedDescription)") }
        refreshInfo()
    }

    // MARK: Transport

    private func prepare(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        player.stop()
        generation += 1
        let gen = generation
        startFrame = frame
        let count = f.length - frame
        guard count > 0 else { return }
        player.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(count), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen else { return }
                self.finished()
            }
        }
    }

    func togglePlay() {
        guard file != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if !engine.isRunning { try? engine.start() }
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        isPlaying = false
        position = 0
        prepare(from: 0)
    }

    func seek(to seconds: Double) {
        guard let f = file else { return }
        let was = isPlaying
        prepare(from: AVAudioFramePosition(seconds * f.processingFormat.sampleRate))
        position = seconds
        if was { player.play() }
    }

    private func finished() {
        addLog("Playback finished")
        stop()
    }

    private func tick() {
        tickCount += 1
        if tickCount % 3 == 0 {      // ~0.3 s: everything on screen stays live
            refreshInfo()
            refreshDecode()
        }
        guard isPlaying, !isSeeking, let f = file,
              let nt = player.lastRenderTime,
              let pt = player.playerTime(forNodeTime: nt) else { return }
        let frame = startFrame + pt.sampleTime
        position = min(max(Double(frame) / f.processingFormat.sampleRate, 0), duration)
    }

    // MARK: Process (live meter)

    private func installMeter() {
        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            func peak(_ c: Int) -> Float {
                var m: Float = 0
                let p = ch[c]
                for i in 0..<n { m = max(m, abs(p[i])) }
                return m
            }
            let l = peak(0)
            let r = buf.format.channelCount > 1 ? peak(1) : l
            func db(_ v: Float) -> Float { v < 0.00003 ? -90 : 20 * log10(v) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.levelL = db(l)
                self.levelR = db(r)
                self.peakL = max(self.peakL, db(l))
                self.peakR = max(self.peakR, db(r))
                if l >= 0.9999 || r >= 0.9999 { self.clips += 1 }
            }
        }
    }

    // MARK: Output path info

    func refreshInfo() {
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs
        let newRoute = outs.isEmpty ? "No output" : outs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        if routeInfo != newRoute { routeInfo = newRoute }
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let newSession = String(format: "Session %.0f Hz (preferred %.0f) · IO buffer %.1f ms · %d out ch · engine out %.0f Hz %d ch",
                                s.sampleRate, s.preferredSampleRate, s.ioBufferDuration * 1000,
                                s.outputNumberOfChannels, hw.sampleRate, hw.channelCount)
        if sessionInfo != newSession { sessionInfo = newSession }
        guard let f = file else {
            if pathText != "-" { pathText = "-" }
            if !checks.isEmpty { checks = [] }
            return
        }
        let fileRate = f.fileFormat.sampleRate
        let rateOK = abs(s.sampleRate - fileRate) < 1 && abs(hw.sampleRate - fileRate) < 1
        let gainStr = gainDB == 0 ? "bypass" : String(format: "%+.1f dB", gainDB)
        let newPath = "\(codecText) \(Int(fileRate)) Hz/\(bitsText) → AVAudioFile decode → Float32 → Player → Gain (\(gainStr)) → Mixer → Output \(Int(hw.sampleRate)) Hz → \(routeInfo)"
        if pathText != newPath { pathText = newPath }
        let newChecks = [
            Check(text: "Output rate = file rate (no resampling)", ok: rateOK),
            Check(text: "Gain/EQ bypassed", ok: gainDB == 0),
            Check(text: "External digital route (USB/Lightning DAC)", ok: outs.contains { $0.portType == .usbAudio }),
        ]
        if checks != newChecks { checks = newChecks }
    }

    // MARK: Live decode readout (refreshes ~3x/sec, also while idle)

    func refreshDecode() {
        let s = AVAudioSession.sharedInstance()
        let hw = engine.outputNode.outputFormat(forBus: 0)
        let outs = s.currentRoute.outputs
        let usb = outs.contains { $0.portType == .usbAudio }
        var rows: [InfoRow] = []

        guard let f = file else {
            rows.append(InfoRow(key: "Decoder", value: "idle · no file loaded"))
            rows.append(InfoRow(key: "Hardware output",
                                value: String(format: "%.0f Hz · %d ch · session %.0f Hz", hw.sampleRate, Int(hw.channelCount), s.sampleRate)))
            if decodeRows != rows { decodeRows = rows }
            return
        }

        let ff = f.fileFormat, pf = f.processingFormat
        let fileRate = ff.sampleRate
        let rateOK = abs(s.sampleRate - fileRate) < 1 && abs(hw.sampleRate - fileRate) < 1
        let total = f.length
        let cur = min(max(Int64(position * pf.sampleRate), 0), Int64(total))
        let pct = total > 0 ? Double(cur) / Double(total) * 100 : 0
        let bitsNum = Int(bitsText) ?? 0

        // Bit-perfect verdict (as far as iOS exposes it)
        var why: [String] = []
        if !rateOK { why.append("resampled \(Int(fileRate))→\(Int(hw.sampleRate)) Hz") }
        if gainDB != 0 { why.append("gain active") }
        if engine.mainMixerNode.outputVolume != 1 { why.append("mixer volume ≠ 1") }
        if !usb { why.append("not a USB DAC route") }
        if bitsNum > 24 { why.append("\(bitsNum)-bit source > Float32 24-bit precision") }
        if Int(hw.channelCount) != Int(pf.channelCount) { why.append("channel count remapped") }
        rows.append(InfoRow(key: "Bit-perfect path",
                            value: why.isEmpty ? "YES" : "NO · " + why.joined(separator: " · ")))

        rows.append(InfoRow(key: "Decoder state",
                            value: "\(isPlaying ? "decoding / playing" : "paused / stopped") · engine \(engine.isRunning ? "running" : "stopped")"))
        rows.append(InfoRow(key: "Codec / container",
                            value: "\(codecText) · .\(f.url.pathExtension.lowercased())"))
        rows.append(InfoRow(key: "Source", value: "\(Int(fileRate)) Hz · \(bitsText) bit · \(ff.channelCount) ch"))
        if fileBytes > 0 && duration > 0 {
            rows.append(InfoRow(key: "Average bitrate",
                                value: String(format: "%.0f kbps · %.1f MB", Double(fileBytes) * 8 / duration / 1000, Double(fileBytes) / 1_048_576)))
        }
        let pcmName = pf.commonFormat == .pcmFormatFloat32 ? "Float32" : "PCM"
        rows.append(InfoRow(key: "Decoded to",
                            value: "\(pcmName) · \(Int(pf.sampleRate)) Hz · \(pf.channelCount) ch · \(pf.isInterleaved ? "interleaved" : "planar")"))
        rows.append(InfoRow(key: "Rate chain",
                            value: String(format: "file %.0f → session %.0f → engine out %.0f Hz · %@",
                                          fileRate, s.sampleRate, hw.sampleRate, rateOK ? "no resampling" : "RESAMPLING")))
        rows.append(InfoRow(key: "Frames decoded / total",
                            value: String(format: "%lld / %lld  (%.1f%%)", cur, Int64(total), pct)))
        rows.append(InfoRow(key: "Time", value: String(format: "%.2f s / %.2f s · %.2f s left", position, duration, max(duration - position, 0))))
        if let nt = player.lastRenderTime {
            rows.append(InfoRow(key: "Player render clock", value: "\(nt.sampleTime) frames"))
        }
        rows.append(InfoRow(key: "Gain stage", value: gainDB == 0 ? "bypass (0 dB)" : String(format: "%+.1f dB", gainDB)))
        rows.append(InfoRow(key: "Level (dBFS)",
                            value: String(format: "L %.1f · R %.1f  |  peak L %.1f · R %.1f", levelL, levelR, peakL, peakR)))
        rows.append(InfoRow(key: "Clipped buffers", value: "\(clips)"))
        rows.append(InfoRow(key: "DAC sink",
                            value: String(format: "%@ · %.0f Hz · IO %.1f ms · latency %.1f ms",
                                          outs.first?.portName ?? "none", s.sampleRate, s.ioBufferDuration * 1000, s.outputLatency * 1000)))

        if decodeRows != rows { decodeRows = rows }
    }

    // MARK: Helpers

    func addLog(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("\(t)  \(s)", at: 0)
        if log.count > 100 { log.removeLast() }
    }

    private func fourCC(_ v: UInt32) -> String {
        let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
        return String(bytes: b, encoding: .ascii) ?? "\(v)"
    }

    private func detectBits(url: URL, asbd: AudioStreamBasicDescription) -> String {
        // FLAC: read STREAMINFO from the header
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            if let d = try? h.read(upToCount: 42), d.count >= 22, d.prefix(4) == Data("fLaC".utf8) {
                let bps = (Int(d[20] & 0x01) << 4) | Int(d[21] >> 4)
                return "\(bps + 1)"
            }
        }
        // ALAC: source bit depth is in the format flags
        if asbd.mFormatID == kAudioFormatAppleLossless {
            switch asbd.mFormatFlags {
            case 1: return "16"
            case 2: return "20"
            case 3: return "24"
            case 4: return "32"
            default: break
            }
        }
        return asbd.mBitsPerChannel > 0 ? "\(asbd.mBitsPerChannel)" : "n/a"
    }
}