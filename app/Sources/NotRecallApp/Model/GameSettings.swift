import Foundation

enum MetalFXSharpness: String, CaseIterable, Identifiable, Equatable {
    case off
    case low
    case high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .high: return "High"
        }
    }
}

enum MouseMode: String, CaseIterable, Identifiable, Equatable {
    case hid
    case precise
    case classic
    case off

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hid: return "High-Precision"
        case .precise: return "Standard"
        case .classic: return "Classic (Recall 1.4)"
        case .off: return "macOS Pointer"
        }
    }

    var detail: String {
        switch self {
        case .hid: return "Reads your mouse directly, skipping macOS’s mouse layer (requires Input Monitoring for Steam; falls back to Standard until granted)."
        case .precise: return "Uses macOS mouse input with mouselook improvements. No permission needed."
        case .classic: return "The mouse behavior from Recall 1.4."
        case .off: return "Standard macOS pointer without Recall mouselook."
        }
    }
}

enum MousePollingLimit: String, CaseIterable, Identifiable, Equatable {
    case all
    case hz2000 = "2000"
    case hz1000 = "1000"
    case hz500 = "500"
    case hz250 = "250"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Reports (Default)"
        case .hz2000: return "2,000 Hz"
        case .hz1000: return "1,000 Hz"
        case .hz500: return "500 Hz"
        case .hz250: return "250 Hz"
        }
    }
}

enum ShaderMemoryBudget: String, CaseIterable, Identifiable, Equatable {
    case all
    case first
    case mb256 = "256"
    case mb512 = "512"
    case mb1024 = "1024"
    case mb2048 = "2048"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All (Default)"
        case .first: return "Slowest Only"
        case .mb256: return "256 MB"
        case .mb512: return "512 MB"
        case .mb1024: return "1 GB"
        case .mb2048: return "2 GB"
        }
    }
}

struct GameSettings: Equatable, Sendable {
    var metalFXUpscaling = false
    var metalFXSharpness: MetalFXSharpness = .off
    var metalHUD = false
    var mouseMode: MouseMode = .hid
    var mouseRate: MousePollingLimit = .all
    var framePacing = true
    var fpsLimit = 0
    var shaderMemory: ShaderMemoryBudget = .all

    // Advanced & troubleshooting
    var fastKeys = false
    var proxyAutoDetect = false
    var gameMode = true
    var backgroundShaderPrep = true
    var rawControllers = false
    var msync = true

    // Diagnostic logging
    var logCrashes = false
    var logGraphics = false
    var logMouse = false

    static let fpsChoices: [Int] = [0, 60, 90, 120, 144, 240]

    static func load(from url: URL) -> GameSettings {
        var s = GameSettings()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return s }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "DXMT_ENABLE_NVEXT":
                s.metalFXUpscaling = (val == "1")
            case "NOTRECALL_METALFX_SHARPNESS":
                if let parsed = MetalFXSharpness(rawValue: val) { s.metalFXSharpness = parsed }
            case "MTL_HUD_ENABLED":
                s.metalHUD = (val == "1")
            case "NOTRECALL_MOUSE_MODE":
                if let parsed = MouseMode(rawValue: val) { s.mouseMode = parsed }
            case "NOTRECALL_MOUSE_RATE":
                if let parsed = MousePollingLimit(rawValue: val) { s.mouseRate = parsed }
            case "NOTRECALL_FRAME_PACING":
                s.framePacing = (val != "off")
            case "NOTRECALL_FPS_LIMIT":
                s.fpsLimit = Int(val) ?? 0
            case "NOTRECALL_SHADER_MEM_MB":
                if let parsed = ShaderMemoryBudget(rawValue: val) { s.shaderMemory = parsed }
            case "WINEMAC_APPKIT_UPDATE_CYCLE":
                s.fastKeys = (val == "0")
            case "NOTRECALL_PROXY_AUTO_DETECT":
                s.proxyAutoDetect = (val == "1")
            case "NOTRECALL_GAME_MODE":
                s.gameMode = (val != "0")
            case "NOTRECALL_SKIP_PRECOMPILE":
                s.backgroundShaderPrep = (val != "1")
            case "NOTRECALL_RAW_CONTROLLERS":
                s.rawControllers = (val == "1")
            case "WINEMSYNC":
                s.msync = (val != "0")
            case "NOTRECALL_LOG_CRASHES":
                s.logCrashes = (val == "1")
            case "NOTRECALL_LOG_GRAPHICS":
                s.logGraphics = (val == "1")
            case "NOTRECALL_LOG_MOUSE":
                s.logMouse = (val == "1")
            default:
                break
            }
        }
        return s
    }

    func serialize() -> String {
        var lines: [String] = [
            "# Managed by NotRecall.app — loaded automatically by compat/run",
            "# Leave Steam Launch Options blank to avoid macOS Steam OS Error 260."
        ]
        if metalFXUpscaling { lines.append("DXMT_ENABLE_NVEXT=1") }
        if metalFXUpscaling && metalFXSharpness != .off {
            lines.append("NOTRECALL_METALFX_SHARPNESS=\(metalFXSharpness.rawValue)")
        }
        if metalHUD { lines.append("MTL_HUD_ENABLED=1") }
        lines.append("NOTRECALL_MOUSE_MODE=\(mouseMode.rawValue)")
        if mouseRate != .all { lines.append("NOTRECALL_MOUSE_RATE=\(mouseRate.rawValue)") }
        if !framePacing { lines.append("NOTRECALL_FRAME_PACING=off") }
        if fpsLimit > 0 { lines.append("NOTRECALL_FPS_LIMIT=\(fpsLimit)") }
        if shaderMemory != .all { lines.append("NOTRECALL_SHADER_MEM_MB=\(shaderMemory.rawValue)") }
        if fastKeys { lines.append("WINEMAC_APPKIT_UPDATE_CYCLE=0") }
        if proxyAutoDetect { lines.append("NOTRECALL_PROXY_AUTO_DETECT=1") }
        if !gameMode { lines.append("NOTRECALL_GAME_MODE=0") }
        if !backgroundShaderPrep { lines.append("NOTRECALL_SKIP_PRECOMPILE=1") }
        if rawControllers { lines.append("NOTRECALL_RAW_CONTROLLERS=1") }
        if !msync { lines.append("WINEMSYNC=0") }
        if logCrashes { lines.append("NOTRECALL_LOG_CRASHES=1") }
        if logGraphics { lines.append("NOTRECALL_LOG_GRAPHICS=1") }
        if logMouse { lines.append("NOTRECALL_LOG_MOUSE=1") }
        return lines.joined(separator: "\n") + "\n"
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try serialize().write(to: url, atomically: true, encoding: .utf8)
    }
}
