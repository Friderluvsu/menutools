import Foundation
import IOKit

public let HELPER_VERSION = "1.1.0"

public struct SMCParamStruct {
    public var key: UInt32 = 0

    // vers (6 bytes)
    public var versMajor: UInt8 = 0
    public var versMinor: UInt8 = 0
    public var versBuild: UInt8 = 0
    public var versReserved: UInt8 = 0
    public var versRelease: UInt16 = 0

    // pLimitData (16 bytes)
    public var pLimitVersion: UInt16 = 0
    public var pLimitLength: UInt16 = 0
    public var cpuPLimit: UInt32 = 0
    public var gpuPLimit: UInt32 = 0
    public var memPLimit: UInt32 = 0

    // keyInfo (9 bytes + 3 padding = 12 bytes)
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0
    public var padding0: UInt8 = 0
    public var padding1: UInt8 = 0
    public var padding2: UInt8 = 0

    // result, status, data8 (3 bytes + 1 padding = 4 bytes)
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var padding3: UInt8 = 0

    // data32 (4 bytes)
    public var data32: UInt32 = 0

    // bytes (32 bytes)
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                      (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    public init() {}
}

final class SMCDriverDirect {
    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard kr == kIOReturnSuccess else { return nil }
    }

    deinit {
        if conn != 0 {
            IOServiceClose(conn)
        }
    }

    private func fourCharCode(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        return result
    }

    private func stringFromFourCharCode(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func smcCall(input: inout SMCParamStruct, output: inout SMCParamStruct) -> kern_return_t {
        let inSize = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(conn, 2, &input, inSize, &output, &outSize)
    }

    func readKey(_ keyStr: String) -> (type: String, size: UInt32, bytes: [UInt8])? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(keyStr)
        input.data8 = 9 // SMC_CMD_READ_KEYINFO

        guard smcCall(input: &input, output: &output) == kIOReturnSuccess && output.result == 0 else {
            return nil
        }

        let size = output.dataSize
        let type = stringFromFourCharCode(output.dataType)

        input = SMCParamStruct()
        output = SMCParamStruct()
        input.key = fourCharCode(keyStr)
        input.dataSize = size
        input.data8 = 5 // SMC_CMD_READ_BYTES

        guard smcCall(input: &input, output: &output) == kIOReturnSuccess && output.result == 0 else {
            return nil
        }

        var arr = [UInt8]()
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<Int(size) {
                arr.append(raw[i])
            }
        }
        return (type, size, arr)
    }

    func writeKey(_ keyStr: String, typeStr: String, bytes: [UInt8]) -> Bool {
        var input = SMCParamStruct()
        var output = SMCParamStruct()
        input.key = fourCharCode(keyStr)
        input.dataSize = UInt32(bytes.count)
        input.dataType = fourCharCode(typeStr)
        input.data8 = 6 // SMC_CMD_WRITE_BYTES

        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for i in 0..<bytes.count {
                raw[i] = bytes[i]
            }
        }

        let kr = smcCall(input: &input, output: &output)
        return kr == kIOReturnSuccess && output.result == 0
    }

    func setAllFansSpeed(targetRPM: Float) -> Bool {
        _ = writeKey("Ftst", typeStr: "ui8 ", bytes: [1])
        let count = readKey("FNum").flatMap { $0.bytes.first.map(Int.init) } ?? 1
        var bitMask: UInt16 = 0
        var allOk = true

        for i in 0..<max(1, count) {
            bitMask |= (1 << i)
            _ = writeKey("F\(i)Md", typeStr: "ui8 ", bytes: [1])
            let targetKey = "F\(i)Tg"
            if let info = readKey(targetKey) {
                if info.type.contains("flt") {
                    var val = targetRPM
                    let bytes = withUnsafeBytes(of: &val) { Array($0) }
                    if !writeKey(targetKey, typeStr: info.type, bytes: bytes) { allOk = false }
                } else {
                    let fpe2Val = UInt16(targetRPM * 4.0)
                    let bytes: [UInt8] = [UInt8((fpe2Val >> 8) & 0xFF), UInt8(fpe2Val & 0xFF)]
                    if !writeKey(targetKey, typeStr: info.type, bytes: bytes) { allOk = false }
                }
            }
        }
        _ = writeKey("FS! ", typeStr: "ui16", bytes: [UInt8((bitMask >> 8) & 0xFF), UInt8(bitMask & 0xFF)])
        return allOk
    }

    func setAllAuto() -> Bool {
        _ = writeKey("Ftst", typeStr: "ui8 ", bytes: [0])
        let count = readKey("FNum").flatMap { $0.bytes.first.map(Int.init) } ?? 1
        for i in 0..<max(1, count) {
            _ = writeKey("F\(i)Md", typeStr: "ui8 ", bytes: [0])
        }
        _ = writeKey("FS! ", typeStr: "ui16", bytes: [0, 0])
        return true
    }
}

guard let driver = SMCDriverDirect() else {
    fputs("Error: Unable to connect to AppleSMC\n", stderr)
    exit(1)
}

let args = CommandLine.arguments

if args.contains("--version") || args.contains("-v") {
    print(HELPER_VERSION)
    exit(0)
}

if args.contains("auto") || args.contains("auto-all") {
    let success = driver.setAllAuto()
    exit(success ? 0 : 1)
} else if let idx = args.firstIndex(of: "set-all"), args.indices.contains(idx + 1) {
    let rpm = Float(args[idx + 1]) ?? 3000.0
    let success = driver.setAllFansSpeed(targetRPM: rpm)
    exit(success ? 0 : 1)
} else if let idx = args.firstIndex(of: "set") {
    if args.indices.contains(idx + 2), let rpm = Float(args[idx + 2]) {
        let success = driver.setAllFansSpeed(targetRPM: rpm)
        exit(success ? 0 : 1)
    } else if args.indices.contains(idx + 1), let rpm = Float(args[idx + 1]) {
        let success = driver.setAllFansSpeed(targetRPM: rpm)
        exit(success ? 0 : 1)
    }
    exit(1)
} else if args.contains("status") {
    if let res = driver.readKey("FNum"), !res.bytes.isEmpty {
        let count = res.bytes[0]
        print("Fans: \(count)")
        for i in 0..<count {
            if let ac = driver.readKey("F\(i)Ac") {
                let rpm = ac.bytes.withUnsafeBytes { $0.load(as: Float.self) }
                print("Fan \(i) Actual: \(rpm)")
            }
            if let tg = driver.readKey("F\(i)Tg") {
                let rpm = tg.bytes.withUnsafeBytes { $0.load(as: Float.self) }
                print("Fan \(i) Target: \(rpm)")
            }
            if let mn = driver.readKey("F\(i)Mn") {
                let rpm = mn.bytes.withUnsafeBytes { $0.load(as: Float.self) }
                print("Fan \(i) Min: \(rpm)")
            }
            if let mx = driver.readKey("F\(i)Mx") {
                let rpm = mx.bytes.withUnsafeBytes { $0.load(as: Float.self) }
                print("Fan \(i) Max: \(rpm)")
            }
        }
    }
    exit(0)
} else if let idx = args.firstIndex(of: "disablesleep"), args.indices.contains(idx + 1) {
    let val = args[idx + 1] == "1" ? "1" : "0"
    setuid(0)
    seteuid(0)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "disablesleep", val]
    do {
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus == 0 ? 0 : 1)
    } catch {
        exit(1)
    }
} else if let idx = args.firstIndex(of: "lowpowermode"), args.indices.contains(idx + 1) {
    let val = args[idx + 1] == "1" ? "1" : "0"
    setuid(0)
    seteuid(0)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-a", "lowpowermode", val]
    do {
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus == 0 ? 0 : 1)
    } catch {
        exit(1)
    }
} else {
    print("Usage: menutools-smc-helper [set <rpm> | set <fanIndex> <rpm> | set-all <rpm> | auto | status | disablesleep <0|1> | lowpowermode <0|1> | --version]")
    exit(1)
}
