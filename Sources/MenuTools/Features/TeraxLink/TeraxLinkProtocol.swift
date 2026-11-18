import Foundation

/// The Terax link: Terax's phone access asks MenuTools for agent sessions, stats and power state over a
/// Unix socket only this user can open, one JSON line each way. Pure types; no AppKit.
enum TeraxLinkProtocol {
    static let version = 1
    static let maxRequestBytes = 16 * 1024
    /// Durations the phone offers, in minutes. 0 means no limit.
    static let allowedMinutes: Set<Int> = [0, 15, 30, 60, 120, 300]

    enum Action: Equatable, Sendable {
        case lock
        case rest(on: Bool)
        case awake(on: Bool, seconds: Int)
        case lid(on: Bool, seconds: Int)
        case lowPower(on: Bool)
        /// Sleep the Mac once every session is done.
        case sleepWhenDone(on: Bool)
        /// Ring here and on the phone once every session is done.
        case wakeWhenDone(on: Bool)
        /// Stop the ringing alarm (`on` false). Starting one is not offered.
        case alarm(on: Bool)
        /// Terax brought the pane whose shell is `pid` to the front: finished sessions running in it
        /// count as checked.
        case paneFocused(pid: Int32)
    }

    enum Request: Equatable, Sendable {
        /// `refresh` re-reads sessions, battery and network before answering.
        case status(refresh: Bool)
        case action(Action)
    }

    private struct RawRequest: Decodable {
        let method: String
        let params: RawParams?
    }

    private struct RawParams: Decodable {
        let name: String?
        let on: Bool?
        let minutes: Int?
        let refresh: Bool?
        let pid: Int?
    }

    /// Parses one request line. Every field is checked; anything unexpected is refused with a reason.
    static func parse(_ line: Data) -> Result<Request, LinkError> {
        guard line.count <= maxRequestBytes else { return .failure(.invalid("request too large")) }
        guard let raw = try? JSONDecoder().decode(RawRequest.self, from: line) else {
            return .failure(.invalid("invalid request"))
        }
        switch raw.method {
        case "status":
            return .success(.status(refresh: raw.params?.refresh == true))
        case "action":
            guard let params = raw.params else { return .failure(.invalid("missing action")) }
            return parseAction(params).map(Request.action)
        default:
            return .failure(.invalid("unknown method"))
        }
    }

    private static func parseAction(_ params: RawParams) -> Result<Action, LinkError> {
        func toggle() -> Result<Bool, LinkError> {
            params.on.map(Result.success) ?? .failure(.invalid("missing on"))
        }
        func seconds() -> Result<Int, LinkError> {
            let minutes = params.minutes ?? 0
            guard allowedMinutes.contains(minutes) else { return .failure(.invalid("unsupported duration")) }
            return .success(minutes * 60)
        }
        guard let name = params.name else { return .failure(.invalid("missing action")) }
        switch name {
        case "lock":
            return .success(.lock)
        case "rest":
            return toggle().map { .rest(on: $0) }
        case "lowPower":
            return toggle().map { .lowPower(on: $0) }
        case "sleepWhenDone":
            return toggle().map { .sleepWhenDone(on: $0) }
        case "wakeWhenDone":
            return toggle().map { .wakeWhenDone(on: $0) }
        case "alarm":
            return toggle().flatMap { on in
                on ? .failure(.invalid("alarm can only be stopped")) : .success(.alarm(on: false))
            }
        case "awake":
            return toggle().flatMap { on in seconds().map { .awake(on: on, seconds: $0) } }
        case "lid":
            return toggle().flatMap { on in seconds().map { .lid(on: on, seconds: $0) } }
        case "paneFocused":
            guard let pid = params.pid, pid > 1, pid <= Int(Int32.max) else { return .failure(.invalid("missing pid")) }
            return .success(.paneFocused(pid: Int32(pid)))
        default:
            return .failure(.invalid("unknown action"))
        }
    }

    enum LinkError: Error, Equatable, Sendable {
        case invalid(String)
        case refused(String)

        var message: String {
            switch self {
            case .invalid(let reason), .refused(let reason): return reason
            }
        }
    }

    private struct Reply<Result: Encodable>: Encodable {
        let ok: Bool
        let result: Result?
        let error: String?
    }

    private static func encode<Result: Encodable>(_ reply: Reply<Result>) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = (try? encoder.encode(reply)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
        data.append(0x0A)
        return data
    }

    static func success(_ status: LinkStatus) -> Data {
        encode(Reply(ok: true, result: status, error: nil))
    }

    static func failure(_ error: LinkError) -> Data {
        encode(Reply<LinkStatus>(ok: false, result: nil, error: error.message))
    }
}

// MARK: Status snapshot

struct LinkStatus: Encodable, Equatable, Sendable {
    var version = TeraxLinkProtocol.version
    /// When MenuTools built this answer, epoch ms.
    var updatedAt: Int64
    /// True when sessions, battery and network were re-read for this answer.
    var refreshed: Bool
    var sessions: [LinkSession]
    var stats: LinkStats
    var battery: LinkBattery?
    var power: LinkPower
}

struct LinkSession: Encodable, Equatable, Sendable {
    enum State: String, Encodable, Sendable {
        case input, running, done, idle, ended

        /// Needs-input first, then working, then the quiet ones.
        var rank: Int {
            switch self {
            case .input: 0
            case .running: 1
            case .done: 2
            case .idle: 3
            case .ended: 4
            }
        }
    }

    var agent: String
    var name: String
    var project: String
    var state: State
    var detail: String?
    /// Start time, or the finish time for done and ended rows.
    var since: Int64?
    var badge: String?
    /// The agent's process, so Terax can find the terminal it runs in. Never shown on the phone.
    var pid: Int32? = nil
}

struct LinkStats: Encodable, Equatable, Sendable {
    struct Disk: Encodable, Equatable, Sendable {
        var usedPercent: Double
        var freeBytes: UInt64
    }

    var cpu: Double
    var cpuHistory: [Double]
    var memory: Double
    var memoryUsedGB: Double
    var memoryTotalGB: Double
    var memoryPressure: String?
    var temperature: Double?
    var gpu: Double?
    var downKBps: Double
    var upKBps: Double
    var load1: Double
    var uptime: Double
    var disk: Disk?
}

struct LinkBattery: Encodable, Equatable, Sendable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    var timeRemaining: String?
}

struct LinkPower: Encodable, Equatable, Sendable {
    struct Timed: Encodable, Equatable, Sendable {
        var on: Bool
        /// Seconds left; nil while on means no time limit.
        var remaining: Int?
        var error: String?
    }

    struct Rest: Encodable, Equatable, Sendable {
        var on: Bool
        var since: Int64?
    }

    struct AfterDone: Encodable, Equatable, Sendable {
        /// Sleep when done is armed.
        var sleep: Bool
        /// Wake me when done is armed.
        var wake: Bool
        /// The alarm is ringing: the phone should ring too, until it sends `alarm` off.
        var alarm: Bool
        var alarmSince: Int64?
        /// What holds the switches up, e.g. "2 running"; absent when everything is done.
        var busy: String?
    }

    var awake: Timed
    var lid: Timed
    var lowPower: Bool
    var rest: Rest
    var afterDone: AfterDone
    var vpn: Bool
    var spoofDPI: Bool
    var helper: Bool
}

enum LinkSessionOrder {
    static let maxEnded = 6
    static let endedWindow: TimeInterval = 12 * 3600

    /// Live rows by state, then the most recent ended rows inside the window.
    static func arrange(_ rows: [LinkSession], nowMs: Int64) -> [LinkSession] {
        let cutoff = nowMs - Int64(endedWindow * 1000)
        let live = rows.filter { $0.state != .ended }
        let ended =
            rows
            .filter { $0.state == .ended && ($0.since ?? 0) >= cutoff }
            .sorted { ($0.since ?? 0) > ($1.since ?? 0) }
            .prefix(maxEnded)
        let ordered = live.enumerated().sorted { lhs, rhs in
            lhs.element.state.rank == rhs.element.state.rank
                ? lhs.offset < rhs.offset : lhs.element.state.rank < rhs.element.state.rank
        }
        return ordered.map(\.element) + ended
    }
}

extension Date {
    var epochMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
