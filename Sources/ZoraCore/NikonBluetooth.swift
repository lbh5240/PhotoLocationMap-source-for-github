import Foundation

// Protocol adaptation: ZPill, Copyright (c) 2026 jaminxx, MIT.
// See ThirdPartyNotices.txt. Cross-model evidence is not Z7 II hardware validation.
public struct NikonBLEIdentity: Codable, Equatable, Sendable {
    public let peripheralID: UUID
    public let device: UInt32
    public let nonce: UInt32
    public let serial: String
    public init(peripheralID: UUID, device: UInt32, nonce: UInt32, serial: String) {
        self.peripheralID = peripheralID; self.device = device; self.nonce = nonce; self.serial = serial
    }
}

public struct NikonPairingFrame: Equatable, Sendable {
    public let stage: UInt8
    public let timestamp: UInt64
    public let device: UInt32
    public let nonce: UInt32
    public init(stage: UInt8, timestamp: UInt64, device: UInt32, nonce: UInt32) {
        self.stage = stage; self.timestamp = timestamp; self.device = device; self.nonce = nonce
    }
    public init(data: Data) throws {
        guard data.count == 17 else { throw ZoraError.malformed("Nikon BLE frame must be 17 bytes") }
        var r = BinaryReader(data)
        stage = try r.integer(); timestamp = try r.integer(); device = try r.integer(); nonce = try r.integer()
    }
    public var data: Data {
        var d = Data([stage]); d.appendLE(timestamp); d.appendLE(device); d.appendLE(nonce); return d
    }
}

/// The state machine verifies the challenge before allowing stage 3, and never
/// treats discovery, link establishment or a control-point request as authentication.
public struct NikonBLEHandshake: Sendable {
    public enum Phase: Equatable, Sendable { case challenge, confirmation, authenticated }
    public private(set) var phase = Phase.challenge
    public let initial: NikonPairingFrame
    public private(set) var serial: String?
    private static let salts: [(UInt32, UInt32)] = [
        (0x704066e4,0x0433d552),(0xed4b8fac,0x15f7e47b),(0x24471f11,0x8b5ea1fc),(0x05960c31,0x2b8c7f41),
        (0xfda588c1,0xeba8b1f3),(0x99166056,0x1bd3d550),(0xcd32687f,0xa9e28a30),(0x2a8fe834,0xdec7ebf4)
    ]
    public init(identity: NikonBLEIdentity? = nil) {
        initial = NikonPairingFrame(stage: 1, timestamp: .random(in: .min ... .max),
            device: identity?.device ?? ((UInt32.random(in: .min ... .max) & 0xffffff00) | 1),
            nonce: identity?.nonce ?? .random(in: .min ... .max))
    }
    public init(initial: NikonPairingFrame) throws {
        guard initial.stage == 1 else { throw ZoraError.malformed("Expected BLE stage 1") }; self.initial = initial
    }
    public mutating func receive(_ data: Data) throws -> Data? {
        let frame = try NikonPairingFrame(data: data)
        switch phase {
        case .challenge:
            guard frame.stage == 2 else { throw ZoraError.malformed("Expected BLE challenge stage 2") }
            let cipher = NikonBlowfish()
            func words(_ ts: UInt64) -> [UInt32] {
                [UInt32(truncatingIfNeeded: ts).byteSwapped, UInt32(ts >> 32).byteSwapped]
            }
            for salt in Self.salts {
                let prefix = [salt.0, salt.1]
                let result = cipher.mac(prefix + words(frame.timestamp) + words(initial.timestamp))
                if result.0 == frame.device.byteSwapped && result.1 == frame.nonce.byteSwapped {
                    let reply = cipher.mac(prefix + words(initial.timestamp) + words(frame.timestamp))
                    phase = .confirmation
                    return NikonPairingFrame(stage: 3, timestamp: initial.timestamp,
                        device: reply.0.byteSwapped, nonce: reply.1.byteSwapped).data
                }
            }
            throw ZoraError.malformed("Nikon BLE challenge authentication failed")
        case .confirmation:
            guard frame.stage == 4 else { throw ZoraError.malformed("Expected BLE confirmation stage 4") }
            let bytes = data.dropFirst(9).prefix { $0 != 0 }
            guard !bytes.isEmpty, bytes.allSatisfy({ (0x20...0x7e).contains($0) }),
                  let value = String(data: bytes, encoding: .ascii) else { throw ZoraError.malformed("Invalid BLE camera serial") }
            serial = value; phase = .authenticated; return nil
        case .authenticated: throw ZoraError.malformed("Repeated BLE authentication frame")
        }
    }
    public func wifiWakeCommand() throws -> Data {
        guard phase == .authenticated else { throw ZoraError.disconnected }
        return Data([0x01])
    }
}

public enum NikonBLEPayload {
    public static func controllerName(_ name: String) throws -> Data {
        guard let encoded = name.data(using: .ascii), !encoded.isEmpty, encoded.count <= 31 else {
            throw ZoraError.malformed("BLE controller name must be 1–31 ASCII bytes")
        }
        return encoded + Data(repeating: 0, count: 32 - encoded.count)
    }
    public static func time(_ now: Date, timeZone: TimeZone = .current) -> Data {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = cal.dateComponents([.year,.month,.day,.hour,.minute,.second], from: now)
        let minutes = timeZone.secondsFromGMT(for: now) / 60
        var result = Data(); result.appendLE(UInt16(parts.year!))
        result.append(contentsOf: [UInt8(parts.month!),UInt8(parts.day!),UInt8(parts.hour!),UInt8(parts.minute!),UInt8(parts.second!),0,
            UInt8(bitPattern: Int8(minutes / 60)), UInt8(bitPattern: Int8(minutes % 60))])
        return result
    }
    /// Retries stop after five attempts; no unbounded background wake loop.
    public static func reconnectDelay(attempt: Int) -> Int? {
        let delays = [2, 4, 8, 16, 30]
        return delays.indices.contains(attempt) ? delays[attempt] : nil
    }
}

/// Standard Blowfish, used solely for the legacy Nikon challenge protocol.
struct NikonBlowfish: Sendable {
    private var p = PBOX_INIT
    private var s = [SBOX0, SBOX1, SBOX2, SBOX3]
    init(key: [UInt8] = [0xff,0xff,0xaa,0x55,0x11,0x22,0x33,0x00]) {
        precondition(!key.isEmpty)
        var index = 0
        for i in p.indices {
            var word: UInt32 = 0
            for _ in 0..<4 { word = (word << 8) | UInt32(key[index]); index = (index + 1) % key.count }
            p[i] ^= word
        }
        var block: (UInt32, UInt32) = (0,0)
        for i in stride(from: 0, to: 18, by: 2) { block = encrypt(block.0, block.1); p[i] = block.0; p[i+1] = block.1 }
        for box in 0..<4 {
            for i in stride(from: 0, to: 256, by: 2) { block = encrypt(block.0, block.1); s[box][i] = block.0; s[box][i+1] = block.1 }
        }
    }
    private func f(_ x: UInt32) -> UInt32 {
        ((s[0][Int(x >> 24)] &+ s[1][Int((x >> 16) & 255)]) ^ s[2][Int((x >> 8) & 255)]) &+ s[3][Int(x & 255)]
    }
    func encrypt(_ left: UInt32, _ right: UInt32) -> (UInt32, UInt32) {
        var l = left, r = right
        for i in 0..<16 { l ^= p[i]; r ^= f(l); swap(&l, &r) }
        swap(&l, &r); r ^= p[16]; l ^= p[17]; return (l,r)
    }
    func mac(_ words: [UInt32]) -> (UInt32, UInt32) {
        precondition(words.count.isMultiple(of: 2))
        var l: UInt32 = 0x01020304, r: UInt32 = 0x05060708
        for i in stride(from: 0, to: words.count, by: 2) { (l,r) = encrypt(words[i] ^ l, words[i+1] ^ r) }
        return (l,r)
    }
}
