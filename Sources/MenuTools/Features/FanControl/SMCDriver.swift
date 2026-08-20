import Foundation
import IOKit

public enum ThermalSensorGroup: String, CaseIterable, Identifiable, Codable {
    case cpuPerformance = "CPU Performance Cores"
    case cpuAverage = "CPU Core Average"
    case cpuEfficiency = "CPU Efficiency Cores"
    case cpuMax = "CPU Maximum Core"
    case gpu = "GPU / Graphics"
    case socPackage = "SoC / Package"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .cpuPerformance: return "CPU Performance"
        case .cpuAverage: return "CPU Average"
        case .cpuEfficiency: return "CPU Efficiency"
        case .cpuMax: return "CPU Max Core"
        case .gpu: return "GPU"
        case .socPackage: return "SoC Package"
        }
    }

    public var icon: String {
        switch self {
        case .cpuPerformance: return "bolt.cpu.fill"
        case .cpuAverage: return "cpu.fill"
        case .cpuEfficiency: return "leaf.fill"
        case .cpuMax: return "flame.fill"
        case .gpu: return "display"
        case .socPackage: return "memorychip.fill"
        }
    }
}

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

public final class SMCDriver: @unchecked Sendable {
    public static let shared = SMCDriver()
    
    private var conn: io_connect_t = 0
    private let lock = NSLock()
    
    public var isAvailable: Bool { conn != 0 }
    
    public init() {
        openConnection()
    }
    
    deinit {
        closeConnection()
    }
    
    private func openConnection() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        if kr != kIOReturnSuccess {
            conn = 0
        }
    }
    
    private func closeConnection() {
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
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
        guard conn != 0 else { return kIOReturnNotOpen }
        let inSize = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(conn, 2, &input, inSize, &output, &outSize)
    }
    
    public func readKey(_ keyStr: String) -> (type: String, size: UInt32, bytes: [UInt8])? {
        lock.lock()
        defer { lock.unlock() }
        
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
    
    public func writeKey(_ keyStr: String, typeStr: String, bytes: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
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
    
    // MARK: - High Level Fan Helpers
    
    public func readFanCount() -> Int {
        if let res = readKey("FNum"), !res.bytes.isEmpty {
            return Int(res.bytes[0])
        }
        return 0
    }
    
    public func readFanActualRPM(_ fanIndex: Int) -> Int {
        let key = "F\(fanIndex)Ac"
        guard let res = readKey(key), !res.bytes.isEmpty else { return 0 }
        return parseRPM(type: res.type, bytes: res.bytes)
    }
    
    public func readFanTargetRPM(_ fanIndex: Int) -> Int {
        let key = "F\(fanIndex)Tg"
        guard let res = readKey(key), !res.bytes.isEmpty else { return 0 }
        return parseRPM(type: res.type, bytes: res.bytes)
    }
    
    public func readFanMinRPM(_ fanIndex: Int) -> Int {
        let key = "F\(fanIndex)Mn"
        guard let res = readKey(key), !res.bytes.isEmpty else { return 1200 }
        let val = parseRPM(type: res.type, bytes: res.bytes)
        return val > 0 ? val : 1200
    }
    
    public func readFanMaxRPM(_ fanIndex: Int) -> Int {
        let key = "F\(fanIndex)Mx"
        guard let res = readKey(key), !res.bytes.isEmpty else { return 6200 }
        let val = parseRPM(type: res.type, bytes: res.bytes)
        return val > 0 ? val : 6200
    }
    
    private func parseRPM(type: String, bytes: [UInt8]) -> Int {
        if type.contains("flt") && bytes.count >= 4 {
            let f = bytes.withUnsafeBytes { $0.load(as: Float.self) }
            return max(0, Int(f.rounded()))
        } else if bytes.count >= 2 {
            let val = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return max(0, Int(Float(val) / 4.0))
        }
        return 0
    }
    
    // MARK: - Temperature Helpers
    
    public func readTemperature(for group: ThermalSensorGroup) -> Double {
        let keys: [String]
        switch group {
        case .cpuPerformance:
            keys = ["Tp2a", "Tp2b", "Tp3a", "Tp3b", "Tp4a", "Tp4b", "Tp5a", "Tp5b", "Tp7a", "Tp7b", "Tp8a", "Tp8b", "Tp9a", "Tp9b", "TC0P", "TC0D", "TC1C"]
        case .cpuEfficiency:
            keys = ["Te0a", "Te0b", "Te0x", "Te0z", "Te3a", "Te3b", "Te3x", "Te3z"]
        case .cpuAverage:
            keys = ["Tc0a", "Tc7a", "Tc8a", "Tc9a", "Tcaa", "Tp2a", "Tp3a", "Te0a", "TC0P", "TC0D"]
        case .cpuMax:
            keys = ["Tc0a", "Tc7a", "Tc8a", "Tc9a", "Tcaa", "Tp2a", "Tp3a", "Tp4a", "Tp5a", "Tp7a", "Tp8a", "Tp9a", "Te0a", "Te3a", "TC0P", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C"]
        case .gpu:
            keys = ["TG0D", "TG0P", "Tg05", "Tg0D", "Tg0P", "TG0B", "TG0T"]
        case .socPackage:
            keys = ["TCMb", "TCMz", "TH0T", "TH0x", "TH0B", "TSCD", "TMVR", "TPMP", "TPSP", "TIOP"]
        }
        
        var validTemps: [Double] = []
        for key in keys {
            if let temp = readSingleKeyTemperature(key) {
                validTemps.append(temp)
            }
        }
        
        if !validTemps.isEmpty {
            if group == .cpuMax {
                return validTemps.max() ?? 45.0
            }
            return validTemps.reduce(0.0, +) / Double(validTemps.count)
        }
        
        return readCPUTemperature()
    }
    
    private func readSingleKeyTemperature(_ key: String) -> Double? {
        guard let res = readKey(key), !res.bytes.isEmpty else { return nil }
        if res.type.contains("flt") && res.bytes.count >= 4 {
            let temp = Double(res.bytes.withUnsafeBytes { $0.load(as: Float.self) })
            if temp >= 15.0 && temp <= 115.0 {
                return temp
            }
        } else if res.type.contains("sp78") && res.bytes.count >= 2 {
            let intPart = Int8(bitPattern: res.bytes[0])
            let fracPart = Double(res.bytes[1]) / 256.0
            let temp = Double(intPart) + fracPart
            if temp >= 15.0 && temp <= 115.0 {
                return temp
            }
        }
        return nil
    }
    
    public func readCPUTemperature() -> Double {
        let sensorKeys = [
            "Tc0a", "Tc7a", "Tc8a", "Tc9a", "Tcaa",
            "Tp2a", "Tp3a", "Tp4a", "Tp5a", "Tp7a", "Tp8a", "Tp9a",
            "Te0a", "Te3a", "Th0a", "Th1a", "Th2a",
            "TCMb", "TCMz", "TH0T", "TH0x", "TSCD",
            "TC0P", "TC0D", "TC0E", "TC0F", "TC1C", "TC2C", "TC3C", "TC4C",
            "Tp09", "Tp0T", "Tp01", "Tp05", "TG0D", "TG0P"
        ]
        
        var validTemps: [Double] = []
        for key in sensorKeys {
            if let temp = readSingleKeyTemperature(key) {
                validTemps.append(temp)
            }
        }
        
        if !validTemps.isEmpty {
            return validTemps.reduce(0.0, +) / Double(validTemps.count)
        }
        
        return 42.0
    }
    
    // MARK: - Direct Write (Works when executing with root / helper)
    
    public func setFanSpeed(fanIndex: Int, targetRPM: Float) -> Bool {
        // 1. Force/Test mode (Apple Silicon)
        _ = writeKey("Ftst", typeStr: "ui8 ", bytes: [1])
        
        // 2. Manual mode for Fan
        let modeKey = "F\(fanIndex)Md"
        _ = writeKey(modeKey, typeStr: "ui8 ", bytes: [1])
        let bitMask = UInt16(1 << fanIndex)
        _ = writeKey("FS! ", typeStr: "ui16", bytes: [UInt8((bitMask >> 8) & 0xFF), UInt8(bitMask & 0xFF)])
        
        // 3. Set target RPM
        let targetKey = "F\(fanIndex)Tg"
        guard let info = readKey(targetKey) else { return false }
        
        if info.type.contains("flt") {
            var val = targetRPM
            let bytes = withUnsafeBytes(of: &val) { Array($0) }
            return writeKey(targetKey, typeStr: info.type, bytes: bytes)
        } else {
            let fpe2Val = UInt16(targetRPM * 4.0)
            let bytes: [UInt8] = [UInt8((fpe2Val >> 8) & 0xFF), UInt8(fpe2Val & 0xFF)]
            return writeKey(targetKey, typeStr: info.type, bytes: bytes)
        }
    }
    
    public func setAuto(fanIndex: Int) -> Bool {
        _ = writeKey("Ftst", typeStr: "ui8 ", bytes: [0])
        let modeKey = "F\(fanIndex)Md"
        _ = writeKey(modeKey, typeStr: "ui8 ", bytes: [0])
        _ = writeKey("FS! ", typeStr: "ui16", bytes: [0, 0])
        return true
    }
}
