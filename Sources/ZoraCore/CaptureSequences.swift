import Foundation

/// Self-timer and intervalometer. Shots are scheduled against absolute slots from the
/// start, so a slow capture delays at most one shot and never accumulates drift.
public struct IntervalPlan: Sendable, Equatable, Codable {
    public var shots: Int
    public var interval: Double
    public var startDelay: Double
    public init(shots: Int, interval: Double, startDelay: Double = 0) {
        self.shots = shots; self.interval = interval; self.startDelay = startDelay
    }
    public static func selfTimer(_ seconds: Double) -> Self { .init(shots: 1, interval: 1, startDelay: seconds) }
    public func validated() throws -> Self {
        guard (1...9999).contains(shots), interval.isFinite, (1...86400).contains(interval),
              startDelay.isFinite, (0...3600).contains(startDelay) else {
            throw ZoraError.malformed("间隔拍摄需 1–9999 张、间隔 1–86400 秒、延时 0–3600 秒")
        }
        return self
    }
    /// Seconds after start for shot `index`.
    public func offset(of index: Int) -> Double { startDelay + Double(index) * interval }
    /// Next shot index that is still in the future (or due now) after `elapsed` seconds.
    /// Overrun slots are skipped rather than fired back-to-back.
    public func nextIndex(after completed: Int, elapsed: Double) -> Int? {
        var next = completed + 1
        while next < shots, offset(of: next) + 0.5 < elapsed { next += 1 }
        return next < shots ? next : nil
    }
    public var totalDuration: Double { offset(of: shots - 1) }
}

/// Exposure bracketing over a camera-declared value list (exposure compensation or shutter).
/// Values are always taken from the camera's own options; nothing is extrapolated.
public struct BracketPlan: Sendable, Equatable {
    public let values: [Int64]
    public let original: Int64
    public static let supportedCodes: [UInt16] = [0x5010, 0x500D, 0x500F]
    /// `frames` odd (3/5/7/9); `spacing` is the number of option positions between frames.
    /// Order follows the common camera convention: 0, −, +, −−, ++ …
    public init(property: CameraProperty, frames: Int, spacing: Int) throws {
        guard [3, 5, 7, 9].contains(frames), (1...12).contains(spacing) else { throw ZoraError.malformed("包围需 3/5/7/9 张，间隔 1–12 档") }
        // Only properties whose numeric order is exposure order. Nikon 0xD100 packs a fraction and is excluded.
        guard Self.supportedCodes.contains(property.code) else { throw ZoraError.unsupported("\(property.title) 不能用于包围曝光") }
        guard property.writable else { throw ZoraError.unsupported("\(property.title) 当前只读，可能需要切换拍摄模式") }
        var values = [property.current]
        for n in 1...(frames / 2) {
            values.append(try property.value(offset: -n * spacing))
            values.append(try property.value(offset: n * spacing))
        }
        guard !values.contains(where: { $0 >= 0xFFFFFFFD }) else { throw ZoraError.unsupported("包围范围会进入 B 门/T 门，请缩小间隔") }
        self.values = values; original = property.current
    }
}

public struct FocusStackPlan: Sendable, Equatable {
    public var shots: Int
    public var steps: UInt32
    public var towardNear: Bool
    public init(shots: Int, steps: UInt32, towardNear: Bool = false) {
        self.shots = shots; self.steps = steps; self.towardNear = towardNear
    }
    public func validated() throws -> Self {
        guard (2...300).contains(shots), (1...32767).contains(steps) else { throw ZoraError.malformed("焦点包围需 2–300 张、步长 1–32767") }
        return self
    }
}
