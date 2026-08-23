import Foundation
import AppKit
import MediaPlayer
import CoreAudio
import Darwin

// MARK: - Config

func resolveSocketPath() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ncspot", "info"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("USER_RUNTIME_PATH") {
                let path = line.replacingOccurrences(of: "USER_RUNTIME_PATH", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return path + "/ncspot.sock"
            }
        }
    } catch {
        FileHandle.standardError.write("could not run `ncspot info`: \(error)\n".data(using: .utf8)!)
    }
    let uid = getuid()
    return "/tmp/ncspot-\(uid)/ncspot.sock"
}

let socketPath = resolveSocketPath()

// MARK: - JSON model
//
// ncspot >= 1.0 pushes PlayerEvent as `mode`:
//   Playing(SystemTime) -> {"Playing":  {"secs_since_epoch": .., "nanos_since_epoch": ..}}
//       SystemTime = wall clock moment the track was at position 0,
//       so current position = now - that timestamp.
//   Paused(Duration)    -> {"Paused": {"secs": .., "nanos": ..}} = frozen position.
//   Stopped             -> {"Stopped": null}

struct NcslotTimeSpec: Decodable {
    let secs: Double?
    let nanos: Double?
    let secs_since_epoch: Double?
    let nanos_since_epoch: Double?

    var durationSeconds: TimeInterval? {
        guard let s = secs else { return nil }
        return s + (nanos ?? 0) / 1_000_000_000.0
    }

    var epochSeconds: TimeInterval? {
        guard let s = secs_since_epoch else { return nil }
        return s + (nanos_since_epoch ?? 0) / 1_000_000_000.0
    }
}

struct NcspotStatus: Decodable {
    struct Playable: Decodable {
        let id: String?
        let title: String?
        let artists: [String]?
        let album: String?
        let duration: Int?
        let cover_url: String?
    }

    enum PlaybackState {
        case playing, paused, stopped
    }

    enum Mode: Decodable {
        case playing(positionZeroAt: TimeInterval)
        case paused(position: TimeInterval)
        case stopped

        private enum CodingKeys: String, CodingKey {
            case Playing, Paused
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                if let spec = try container.decodeIfPresent(NcslotTimeSpec.self, forKey: .Playing),
                   let zeroAt = spec.epochSeconds {
                    self = .playing(positionZeroAt: zeroAt)
                    return
                }
                if let spec = try container.decodeIfPresent(NcslotTimeSpec.self, forKey: .Paused),
                   let position = spec.durationSeconds {
                    self = .paused(position: position)
                    return
                }
            }
            self = .stopped
        }

        var state: PlaybackState {
            switch self {
            case .playing: return .playing
            case .paused: return .paused
            case .stopped: return .stopped
            }
        }

        func position(at date: Date = Date()) -> TimeInterval? {
            switch self {
            case .playing(let positionZeroAt):
                return max(0, date.timeIntervalSince1970 - positionZeroAt)
            case .paused(let position):
                return max(0, position)
            case .stopped:
                return nil
            }
        }
    }

    let mode: Mode?
    let playable: Playable?
}

// MARK: - Now Playing bridge

final class NowPlayingBridge {

    struct Snapshot {
        let trackID: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let artworkURL: URL?
        let mode: NcspotStatus.Mode
    }

    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private(set) var snapshot: Snapshot?
    private var generation = 0

    func update(from status: NcspotStatus) {
        guard let track = status.playable else {
            clear()
            return
        }

        let mode = status.mode ?? .stopped
        let artist = track.artists?.joined(separator: ", ") ?? ""
        let duration = Double(track.duration ?? 0) / 1000.0
        let position = mode.position() ?? 0

        FileHandle.standardError.write(
            ("[status] \(mode.state == .playing ? "playing" : (mode.state == .paused ? "paused" : "stopped")) "
            + "@ \(Int(position))s | \(track.title ?? "?") — \(artist)\n").data(using: .utf8)!)

        snapshot = Snapshot(
            trackID: track.id ?? track.title ?? "",
            title: track.title ?? "Unknown",
            artist: artist,
            album: track.album ?? "",
            duration: duration,
            artworkURL: track.cover_url.flatMap { URL(string: $0) },
            mode: mode)

        publish()
    }

    func republish() {
        guard snapshot != nil else { return }
        publish()
    }

    func clear() {
        generation += 1
        snapshot = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func publish() {
        guard let snap = snapshot else { return }
        generation += 1
        let gen = generation

        var position = snap.mode.position() ?? 0
        if snap.duration > 0 {
            position = min(position, snap.duration)
        }

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = snap.title
        info[MPMediaItemPropertyArtist] = snap.artist
        info[MPMediaItemPropertyAlbumTitle] = snap.album
        if snap.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snap.duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] =
            snap.mode.state == .playing ? 1.0 : 0.0

        let center = MPNowPlayingInfoCenter.default()
        switch snap.mode.state {
        case .playing: center.playbackState = .playing
        case .paused: center.playbackState = .paused
        case .stopped: center.playbackState = .stopped
        }

        func apply(_ artwork: MPMediaItemArtwork?) {
            guard gen == generation else { return }
            var finalInfo = info
            if let artwork = artwork {
                finalInfo[MPMediaItemPropertyArtwork] = artwork
            }
            center.nowPlayingInfo = finalInfo
        }

        if let url = snap.artworkURL {
            loadArtwork(url: url, completion: apply)
        } else {
            apply(nil)
        }
    }

    private func loadArtwork(url: URL, completion: @escaping (MPMediaItemArtwork?) -> Void) {
        if let cached = artworkCache[url.absoluteString] {
            completion(cached)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var result: MPMediaItemArtwork?
            if let data = data, let image = NSImage(data: data) {
                result = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                if let result = result {
                    self.artworkCache[url.absoluteString] = result
                }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

// MARK: - Foreign audio detection (is another app playing sound right now?)

enum AudioActivity {
    case clear
    case foreign
    case unknown
}

enum AudioActivityDetector {

    static func check(nowPlayingPID: pid_t = getpid()) -> AudioActivity {
        guard let pids = audibleOutputProcesses() else { return .unknown }
        for pid in pids {
            if pid == nowPlayingPID { continue }
            guard let path = executablePath(of: pid) else { continue }
            let name = (path as NSString).lastPathComponent
            if name == "ncspot" || name.hasPrefix("ncspot-bridge") { continue }
            if path.hasPrefix("/System/")
                || path.hasPrefix("/usr/libexec/")
                || path.hasPrefix("/usr/sbin/")
                || path.hasPrefix("/sbin/") { continue }
            return .foreign
        }
        return .clear
    }

    private static func audibleOutputProcesses() -> [pid_t]? {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr,
            size > 0 else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size,
            &objectIDs) == noErr else { return nil }

        var pids: [pid_t] = []
        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(
                objectID, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }

            var runAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(
                objectID, &runAddress, 0, nil, &runningSize, &running) == noErr,
                running == 0 { continue }

            pids.append(pid)
        }
        return pids
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Remote command bridge (Control Center -> ncspot)

func log(_ message: String) {
    FileHandle.standardError.write(message.data(using: .utf8)!)
}

func sendCommand(_ command: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("[remote] failed to create socket\n")
            return
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let ptr = rawPtr.bindMemory(to: CChar.self)
            socketPath.withCString { cstr in
                strncpy(ptr.baseAddress, cstr, socketPath.utf8.count)
            }
        }
        let size = MemoryLayout.size(ofValue: addr)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(size))
            }
        }
        guard connected == 0 else {
            log("[remote] connect() failed, errno=\(errno) (\(String(cString: strerror(errno))))\n")
            return
        }

        let msg = command + "\n"
        let written = msg.withCString { write(fd, $0, strlen($0)) }
        if written < 0 {
            log("[remote] write() FAILED, errno=\(errno)\n")
        } else {
            usleep(50_000)
        }
    }
}

func setupRemoteCommands(bridge: NowPlayingBridge) {
    let commandCenter = MPRemoteCommandCenter.shared()

    commandCenter.playCommand.isEnabled = true
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.nextTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.isEnabled = true

    commandCenter.playCommand.addTarget { _ in
        sendCommand("playpause")
        return .success
    }
    commandCenter.pauseCommand.addTarget { _ in
        sendCommand("playpause")
        return .success
    }
    commandCenter.togglePlayPauseCommand.addTarget { _ in
        sendCommand("playpause")
        return .success
    }
    commandCenter.nextTrackCommand.addTarget { _ in
        sendCommand("next")
        return .success
    }
    commandCenter.previousTrackCommand.addTarget { _ in
        sendCommand("previous")
        return .success
    }
    commandCenter.changePlaybackPositionCommand.addTarget { event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
        }
        let targetMs = Int(max(0, event.positionTime) * 1000)
        sendCommand("seek \(targetMs)")
        return .success
    }
}

// MARK: - Socket listener loop

func listenLoop(bridge: NowPlayingBridge) {
    var failedConnects = 0

    while true {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { sleep(2); continue }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            let ptr = rawPtr.bindMemory(to: CChar.self)
            socketPath.withCString { cstr in
                strncpy(ptr.baseAddress, cstr, socketPath.utf8.count)
            }
        }
        let size = MemoryLayout.size(ofValue: addr)
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(size))
            }
        }

        guard connected == 0 else {
            close(fd)
            failedConnects += 1
            if failedConnects == 5 {
                log("[socket] ncspot unreachable, clearing now playing\n")
                DispatchQueue.main.async { bridge.clear() }
            }
            sleep(2)
            continue
        }
        failedConnects = 0

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if line.isEmpty { continue }
                do {
                    let status = try JSONDecoder().decode(NcspotStatus.self, from: Data(line))
                    DispatchQueue.main.async { bridge.update(from: status) }
                } catch {
                    log("parse error: \(error)\n")
                }
            }
        }
        close(fd)
        log("[socket] connection lost, reconnecting\n")
        sleep(1)
    }
}

// MARK: - Heartbeat (reclaim Now Playing after other apps stop playing)

let sharedBridge = NowPlayingBridge()

var slowHeartbeatCounter = 0

func heartbeatTick() {
    guard let snap = sharedBridge.snapshot, snap.mode.state == .playing else { return }
    switch AudioActivityDetector.check() {
    case .clear:
        sharedBridge.republish()
    case .foreign:
        break
    case .unknown:
        slowHeartbeatCounter += 1
        if slowHeartbeatCounter % 12 == 0 {
            sharedBridge.republish()
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

setupRemoteCommands(bridge: sharedBridge)

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
    heartbeatTick()
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if case .clear = AudioActivityDetector.check() {
            sharedBridge.republish()
        }
    }
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    sharedBridge.republish()
}

let queue = DispatchQueue(label: "socket-listener")
queue.async {
    listenLoop(bridge: sharedBridge)
}

app.run()
