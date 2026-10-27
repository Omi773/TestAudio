import AVFoundation
import AudioToolbox
import ExternalAccessory
import UIKit

struct InfoRow: Identifiable, Equatable {
    let key: String
    let value: String
    var id: String { key }
}

/// Live view of everything iOS exposes about the connected DAC (Jcally JM7L).
/// iOS gives apps no raw USB/Lightning access, so this reads the audio route,
/// the audio session, and the engine's hardware output unit.
final class DACMonitor: ObservableObject {
    @Published var connected = false
    @Published var headline = "No output"
    @Published var connectedSince: Date?
    @Published var status: [InfoRow] = []
    @Published var link: [InfoRow] = []
    @Published var system: [InfoRow] = []
    @Published var rates: [InfoRow] = []
    @Published var events: [String] = []
    @Published var probing = false

    private weak var engine: AVAudioEngine?
    private let session = AVAudioSession.sharedInstance()
    private var timer: Timer?
    private var connects = 0
    private var disconnects = 0
    private var lastChange = "-"

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            self?.routeChanged(n)
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("Media services were reset")
            self?.refresh()
        }
        nc.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { [weak self] n in
            let t = (n.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt) ?? 0
            self?.log("Silence-secondary-audio hint: \(t == 1 ? "begin" : "end")")
            self?.refresh()
        }
        nc.addObserver(forName: .EAAccessoryDidConnect, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[EAAccessoryKey] as? EAAccessory
            self?.log("MFi accessory connected: \(a?.name ?? "?")")
            self?.refresh()
        }
        nc.addObserver(forName: .EAAccessoryDidDisconnect, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[EAAccessoryKey] as? EAAccessory
            self?.log("MFi accessory disconnected: \(a?.name ?? "?")")
            self?.refresh()
        }
        EAAccessoryManager.shared().registerForLocalNotifications()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Give the monitor the playback engine so it can read the hardware output unit.
    func attach(engine: AVAudioEngine) {
        guard self.engine == nil else { return }
        self.engine = engine
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.log("Engine configuration changed")
            self?.refresh()
        }
        refresh()
    }

    // MARK: Refresh

    func refresh() {
        let s = session
        let outs = s.currentRoute.outputs
        let out = outs.first
        let usb = outs.contains { $0.portType == .usbAudio }

        if usb != connected {
            if usb {
                connects += 1
                connectedSince = Date()
                log("DAC connected: \(out?.portName ?? "?")")
            } else {
                disconnects += 1
                connectedSince = nil
                log("DAC disconnected")
            }
            connected = usb
        }
        let newHead = out?.portName ?? "No output"
        if headline != newHead { headline = newHead }

        // Status
        let acc = EAAccessoryManager.shared().connectedAccessories
        let accText = acc.isEmpty
            ? "none (class-compliant USB audio DACs usually aren't listed here)"
            : acc.map { "\($0.name) · \($0.manufacturer) · \($0.modelNumber) · fw \($0.firmwareRevision) · hw \($0.hardwareRevision) · s/n \($0.serialNumber)" }.joined(separator: "\n")
        let newStatus = [
            InfoRow(key: "State", value: usb ? "Connected (USB audio)" : "Not connected as USB audio"),
            InfoRow(key: "Name", value: out?.portName ?? "-"),
            InfoRow(key: "Port type", value: out?.portType.rawValue ?? "-"),
            InfoRow(key: "UID", value: out?.uid ?? "-"),
            InfoRow(key: "All outputs", value: routeText(s.currentRoute)),
            InfoRow(key: "Connects / disconnects (this launch)", value: "\(connects) / \(disconnects)"),
            InfoRow(key: "Last route change", value: lastChange),
            InfoRow(key: "MFi accessories", value: accText),
        ]
        if status != newStatus { status = newStatus }

        // Link / format
        let chans = (out?.channels ?? []).map { "\($0.channelNumber): \($0.channelName)" }
        let srcs = (out?.dataSources ?? []).map { $0.dataSourceName }
        var newLink = [
            InfoRow(key: "Session sample rate", value: String(format: "%.0f Hz", s.sampleRate)),
            InfoRow(key: "Preferred sample rate", value: String(format: "%.0f Hz", s.preferredSampleRate)),
            InfoRow(key: "IO buffer (actual / preferred)", value: String(format: "%.2f ms / %.2f ms", s.ioBufferDuration * 1000, s.preferredIOBufferDuration * 1000)),
            InfoRow(key: "Output latency", value: String(format: "%.2f ms", s.outputLatency * 1000)),
            InfoRow(key: "Input latency", value: String(format: "%.2f ms", s.inputLatency * 1000)),
            InfoRow(key: "Output channels (now / max / preferred)", value: "\(s.outputNumberOfChannels) / \(s.maximumOutputNumberOfChannels) / \(s.preferredOutputNumberOfChannels)"),
            InfoRow(key: "Channel map", value: chans.isEmpty ? "-" : chans.joined(separator: ", ")),
            InfoRow(key: "Data sources", value: srcs.isEmpty ? "none" : srcs.joined(separator: ", ")),
            InfoRow(key: "Selected data source", value: out?.selectedDataSource?.dataSourceName ?? "none"),
            InfoRow(key: "Spatial audio", value: (out?.isSpatialAudioEnabled ?? false) ? "on" : "off"),
        ]
        if let e = engine {
            newLink.append(InfoRow(key: "Engine running", value: e.isRunning ? "yes" : "no"))
            newLink.append(InfoRow(key: "Engine → output node (app side)", value: fmt(e.outputNode.inputFormat(forBus: 0))))
            newLink.append(InfoRow(key: "Engine → output node (hardware side)", value: fmt(e.outputNode.outputFormat(forBus: 0))))
            if let au = e.outputNode.audioUnit {
                var asbd = AudioStreamBasicDescription()
                if getProp(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd) {
                    newLink.append(InfoRow(key: "Hardware stream format (AudioUnit)", value: describe(asbd)))
                }
                var lat: Float64 = 0
                if getProp(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &lat) {
                    newLink.append(InfoRow(key: "Output unit latency", value: String(format: "%.2f ms", lat * 1000)))
                }
                var frames: UInt32 = 0
                if getProp(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames) {
                    newLink.append(InfoRow(key: "Max frames per slice", value: "\(frames)"))
                }
                var running: UInt32 = 0
                if getProp(au, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running) {
                    newLink.append(InfoRow(key: "Output unit running", value: running != 0 ? "yes" : "no"))
                }
            }
        }
        if link != newLink { link = newLink }

        // System audio session
        let ins = s.currentRoute.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }
        let avail = (s.availableInputs ?? []).map { "\($0.portName) [\($0.portType.rawValue)]" }
        let newSystem = [
            InfoRow(key: "System volume", value: String(format: "%.0f%%", s.outputVolume * 100)),
            InfoRow(key: "Category / mode", value: "\(s.category.rawValue) / \(s.mode.rawValue)"),
            InfoRow(key: "Route sharing policy", value: policyName(s.routeSharingPolicy)),
            InfoRow(key: "Other audio playing", value: s.isOtherAudioPlaying ? "yes" : "no"),
            InfoRow(key: "Silence-secondary-audio hint", value: s.secondaryAudioShouldBeSilencedHint ? "yes" : "no"),
            InfoRow(key: "Current inputs", value: ins.isEmpty ? "none" : ins.joined(separator: ", ")),
            InfoRow(key: "Available inputs", value: avail.isEmpty ? "none" : avail.joined(separator: ", ")),
        ]
        if system != newSystem { system = newSystem }
    }

    // MARK: Probe supported rates

    /// Requests each rate from the DAC and records what iOS actually grants.
    /// Stop playback first; the original preferred rate is restored afterwards.
    func probeRates() {
        guard !probing else { return }
        probing = true
        let s = session
        let prior = s.preferredSampleRate > 0 ? s.preferredSampleRate : s.sampleRate
        let list: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        Task { @MainActor in
            var out: [InfoRow] = []
            try? s.setActive(true)
            for r in list {
                try? s.setPreferredSampleRate(r)
                try? s.setActive(true)
                try? await Task.sleep(nanoseconds: 250_000_000)
                let got = s.sampleRate
                out.append(InfoRow(key: "\(Int(r)) Hz",
                                   value: abs(got - r) < 1 ? "granted" : String(format: "not granted (got %.0f Hz)", got)))
            }
            try? s.setPreferredSampleRate(prior)
            try? s.setActive(true)
            self.rates = out
            self.log("Rate probe finished")
            self.probing = false
            self.refresh()
        }
    }

    // MARK: Events

    private func routeChanged(_ n: Notification) {
        let raw = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map(reasonName) ?? "unknown(\(raw))"
        let prev = (n.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription).map(routeText) ?? "-"
        lastChange = reason
        log("Route change: \(reason) · was \(prev) · now \(routeText(session.currentRoute))")
        refresh()
    }

    private func log(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        events.insert("\(t)  \(s)", at: 0)
        if events.count > 60 { events.removeLast() }
    }

    // MARK: Helpers

    private func routeText(_ r: AVAudioSessionRouteDescription) -> String {
        r.outputs.isEmpty ? "none" : r.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    }

    private func reasonName(_ r: AVAudioSession.RouteChangeReason) -> String {
        switch r {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "new device available"
        case .oldDeviceUnavailable: return "old device unavailable"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "route configuration change"
        @unknown default: return "other"
        }
    }

    private func policyName(_ p: AVAudioSession.RouteSharingPolicy) -> String {
        switch p {
        case .default: return "default"
        case .longFormAudio: return "long-form audio"
        case .longFormVideo: return "long-form video"
        case .independent: return "independent"
        @unknown default: return "other"
        }
    }

    private func fmt(_ f: AVAudioFormat) -> String {
        let name: String
        switch f.commonFormat {
        case .pcmFormatFloat32: name = "Float32"
        case .pcmFormatFloat64: name = "Float64"
        case .pcmFormatInt16: name = "Int16"
        case .pcmFormatInt32: name = "Int32"
        default: name = "other"
        }
        return "\(Int(f.sampleRate)) Hz · \(f.channelCount) ch · \(name) · \(f.isInterleaved ? "interleaved" : "planar")"
    }

    private func describe(_ a: AudioStreamBasicDescription) -> String {
        let isFloat = (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let planar = (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return "\(Int(a.mSampleRate)) Hz · \(isFloat ? "Float" : "Int")\(a.mBitsPerChannel) · \(a.mChannelsPerFrame) ch · \(planar ? "planar" : "interleaved")"
    }

    private func getProp<T>(_ au: AudioUnit, _ id: AudioUnitPropertyID, _ scope: AudioUnitScope,
                            _ element: AudioUnitElement, _ value: inout T) -> Bool {
        var size = UInt32(MemoryLayout<T>.size)
        return AudioUnitGetProperty(au, id, scope, element, &value, &size) == noErr
    }
}
