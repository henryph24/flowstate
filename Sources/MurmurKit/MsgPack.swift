import Foundation

/// Minimal, dependency-free MessagePack codec — only the subset Murmur needs to
/// talk to the Kyutai `moshi-server` STT WebSocket (`/api/asr-streaming`).
///
/// Two halves:
///  - `MsgPackWriter`: an incremental byte builder used by the engine's pure
///    request builders. Efficient enough for the per-frame audio hot path
///    (`writeFloat32Array`).
///  - `MsgPackValue` + `decode`: a reader for the server's reply messages.
///
/// MessagePack integers/floats are big-endian on the wire. This implementation
/// is intentionally partial: it covers nil/bool/int/uint/float32/float64/str/
/// bin/array/map — everything the STT protocol uses — and rejects the rest.

// MARK: - Writer

public struct MsgPackWriter {
    public private(set) var data = Data()
    public init() {}

    public mutating func writeNil() { data.append(0xC0) }

    public mutating func writeBool(_ b: Bool) { data.append(b ? 0xC3 : 0xC2) }

    public mutating func writeInt(_ value: Int) {
        if value >= 0 {
            writeUInt(UInt64(value))
        } else if value >= -32 {
            data.append(UInt8(bitPattern: Int8(value)))               // negative fixint
        } else if value >= Int(Int8.min) {
            data.append(0xD0); data.append(UInt8(bitPattern: Int8(value)))
        } else if value >= Int(Int16.min) {
            data.append(0xD1); appendBE(UInt16(bitPattern: Int16(value)))
        } else if value >= Int(Int32.min) {
            data.append(0xD2); appendBE(UInt32(bitPattern: Int32(value)))
        } else {
            data.append(0xD3); appendBE(UInt64(bitPattern: Int64(value)))
        }
    }

    public mutating func writeUInt(_ value: UInt64) {
        switch value {
        case 0...0x7F:                data.append(UInt8(value))       // positive fixint
        case 0x80...0xFF:             data.append(0xCC); data.append(UInt8(value))
        case 0x100...0xFFFF:          data.append(0xCD); appendBE(UInt16(value))
        case 0x1_0000...0xFFFF_FFFF:  data.append(0xCE); appendBE(UInt32(value))
        default:                      data.append(0xCF); appendBE(value)
        }
    }

    public mutating func writeFloat32(_ f: Float) { data.append(0xCA); appendBE(f.bitPattern) }

    public mutating func writeFloat64(_ d: Double) { data.append(0xCB); appendBE(d.bitPattern) }

    public mutating func writeString(_ s: String) {
        let bytes = Array(s.utf8)
        switch bytes.count {
        case 0...0x1F:        data.append(0xA0 | UInt8(bytes.count))  // fixstr
        case 0x20...0xFF:     data.append(0xD9); data.append(UInt8(bytes.count))
        case 0x100...0xFFFF:  data.append(0xDA); appendBE(UInt16(bytes.count))
        default:              data.append(0xDB); appendBE(UInt32(bytes.count))
        }
        data.append(contentsOf: bytes)
    }

    public mutating func writeBinary(_ d: Data) {
        switch d.count {
        case 0...0xFF:        data.append(0xC4); data.append(UInt8(d.count))
        case 0x100...0xFFFF:  data.append(0xC5); appendBE(UInt16(d.count))
        default:              data.append(0xC6); appendBE(UInt32(d.count))
        }
        data.append(d)
    }

    public mutating func writeMapHeader(_ count: Int) {
        if count <= 0x0F { data.append(0x80 | UInt8(count)) }
        else if count <= 0xFFFF { data.append(0xDE); appendBE(UInt16(count)) }
        else { data.append(0xDF); appendBE(UInt32(count)) }
    }

    public mutating func writeArrayHeader(_ count: Int) {
        if count <= 0x0F { data.append(0x90 | UInt8(count)) }
        else if count <= 0xFFFF { data.append(0xDC); appendBE(UInt16(count)) }
        else { data.append(0xDD); appendBE(UInt32(count)) }
    }

    /// Efficient bulk-encode of a Float32 array — the audio hot path
    /// (`Audio.pcm`): array header followed by one float32 per sample.
    public mutating func writeFloat32Array(_ xs: [Float]) {
        writeArrayHeader(xs.count)
        data.reserveCapacity(data.count + xs.count * 5)
        for x in xs { data.append(0xCA); appendBE(x.bitPattern) }
    }

    private mutating func appendBE(_ v: UInt16) {
        data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF))
    }
    private mutating func appendBE(_ v: UInt32) {
        data.append(UInt8((v >> 24) & 0xFF)); data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8(v & 0xFF))
    }
    private mutating func appendBE(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
    }
}

// MARK: - Reader

public indirect enum MsgPackValue {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map([String: MsgPackValue])

    public enum DecodeError: Error, Equatable { case truncated, unsupported(UInt8), nonStringKey, tooDeep }

    /// Bound on container nesting. The Kyutai STT protocol never nests beyond a
    /// couple of levels; a deeply-nested frame from a hostile/compromised server
    /// would otherwise overflow the stack (unbounded recursion → SIGSEGV).
    static let maxDepth = 100

    public static func decode(_ data: Data) throws -> MsgPackValue {
        let bytes = [UInt8](data)
        var cursor = 0
        return try decodeValue(bytes, &cursor, depth: 0)
    }

    // MARK: typed accessors (forgiving numeric coercions)

    public subscript(key: String) -> MsgPackValue? {
        if case .map(let m) = self { return m[key] }
        return nil
    }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .uint(let u):   return Double(u)
        default:             return nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let i):    return Int(exactly: i)
        case .uint(let u):   return Int(exactly: u)
        // Int(exactly:) rejects NaN/±Inf and out-of-range magnitudes instead of
        // trapping — a malformed float id must not crash the app.
        case .double(let d): return Int(exactly: d.rounded(.towardZero))
        default:             return nil
        }
    }
    public var arrayValue: [MsgPackValue]? { if case .array(let a) = self { return a }; return nil }
    public var floatArrayValue: [Float]? {
        guard case .array(let a) = self else { return nil }
        return a.compactMap { $0.doubleValue.map(Float.init) }
    }

    /// Re-encode (used for round-trip tests). Map key order is unspecified.
    public func encode() -> Data {
        var w = MsgPackWriter()
        encode(into: &w)
        return w.data
    }
    private func encode(into w: inout MsgPackWriter) {
        switch self {
        case .nil:           w.writeNil()
        case .bool(let b):   w.writeBool(b)
        case .int(let i):    w.writeInt(Int(i))
        case .uint(let u):   w.writeUInt(u)
        case .double(let d): w.writeFloat64(d)
        case .string(let s): w.writeString(s)
        case .binary(let d): w.writeBinary(d)
        case .array(let a):  w.writeArrayHeader(a.count); for v in a { v.encode(into: &w) }
        case .map(let m):    w.writeMapHeader(m.count); for (k, v) in m { w.writeString(k); v.encode(into: &w) }
        }
    }
}

// MARK: - Decoder internals

private func decodeValue(_ b: [UInt8], _ i: inout Int, depth: Int) throws -> MsgPackValue {
    guard depth <= MsgPackValue.maxDepth else { throw MsgPackValue.DecodeError.tooDeep }
    guard i < b.count else { throw MsgPackValue.DecodeError.truncated }
    let c = b[i]; i += 1
    switch c {
    case 0x00...0x7F: return .uint(UInt64(c))
    case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: c)))
    case 0x80...0x8F: return try decodeMap(b, &i, count: Int(c & 0x0F), depth: depth)
    case 0x90...0x9F: return try decodeArray(b, &i, count: Int(c & 0x0F), depth: depth)
    case 0xA0...0xBF: return try decodeStr(b, &i, count: Int(c & 0x1F))
    case 0xC0:        return .nil
    case 0xC2:        return .bool(false)
    case 0xC3:        return .bool(true)
    case 0xC4:        return try decodeBin(b, &i, count: Int(try readByte(b, &i)))
    case 0xC5:        return try decodeBin(b, &i, count: Int(try readBE16(b, &i)))
    case 0xC6:        return try decodeBin(b, &i, count: Int(try readBE32(b, &i)))
    case 0xCA:        return .double(Double(Float(bitPattern: try readBE32(b, &i))))
    case 0xCB:        return .double(Double(bitPattern: try readBE64(b, &i)))
    case 0xCC:        return .uint(UInt64(try readByte(b, &i)))
    case 0xCD:        return .uint(UInt64(try readBE16(b, &i)))
    case 0xCE:        return .uint(UInt64(try readBE32(b, &i)))
    case 0xCF:        return .uint(try readBE64(b, &i))
    case 0xD0:        return .int(Int64(Int8(bitPattern: try readByte(b, &i))))
    case 0xD1:        return .int(Int64(Int16(bitPattern: try readBE16(b, &i))))
    case 0xD2:        return .int(Int64(Int32(bitPattern: try readBE32(b, &i))))
    case 0xD3:        return .int(Int64(bitPattern: try readBE64(b, &i)))
    case 0xD9:        return try decodeStr(b, &i, count: Int(try readByte(b, &i)))
    case 0xDA:        return try decodeStr(b, &i, count: Int(try readBE16(b, &i)))
    case 0xDB:        return try decodeStr(b, &i, count: Int(try readBE32(b, &i)))
    case 0xDC:        return try decodeArray(b, &i, count: Int(try readBE16(b, &i)), depth: depth)
    case 0xDD:        return try decodeArray(b, &i, count: Int(try readBE32(b, &i)), depth: depth)
    case 0xDE:        return try decodeMap(b, &i, count: Int(try readBE16(b, &i)), depth: depth)
    case 0xDF:        return try decodeMap(b, &i, count: Int(try readBE32(b, &i)), depth: depth)
    default:          throw MsgPackValue.DecodeError.unsupported(c)
    }
}

private func decodeMap(_ b: [UInt8], _ i: inout Int, count: Int, depth: Int) throws -> MsgPackValue {
    // Each entry needs ≥2 bytes (≥1-byte key + ≥1-byte value); reject an inflated
    // length before reserving, so an attacker-supplied count can't drive a huge
    // allocation / CPU stall.
    guard count <= (b.count - i) / 2 else { throw MsgPackValue.DecodeError.truncated }
    var m = [String: MsgPackValue](minimumCapacity: count)
    for _ in 0..<count {
        let key = try decodeValue(b, &i, depth: depth + 1)
        guard case .string(let k) = key else { throw MsgPackValue.DecodeError.nonStringKey }
        m[k] = try decodeValue(b, &i, depth: depth + 1)
    }
    return .map(m)
}

private func decodeArray(_ b: [UInt8], _ i: inout Int, count: Int, depth: Int) throws -> MsgPackValue {
    // Each element needs ≥1 byte; reject an inflated length before reserving.
    guard count <= b.count - i else { throw MsgPackValue.DecodeError.truncated }
    var a = [MsgPackValue](); a.reserveCapacity(count)
    for _ in 0..<count { a.append(try decodeValue(b, &i, depth: depth + 1)) }
    return .array(a)
}

private func decodeStr(_ b: [UInt8], _ i: inout Int, count: Int) throws -> MsgPackValue {
    guard i + count <= b.count else { throw MsgPackValue.DecodeError.truncated }
    let s = String(decoding: b[i..<i + count], as: UTF8.self)
    i += count
    return .string(s)
}

private func decodeBin(_ b: [UInt8], _ i: inout Int, count: Int) throws -> MsgPackValue {
    guard i + count <= b.count else { throw MsgPackValue.DecodeError.truncated }
    let d = Data(b[i..<i + count])
    i += count
    return .binary(d)
}

private func readByte(_ b: [UInt8], _ i: inout Int) throws -> UInt8 {
    guard i < b.count else { throw MsgPackValue.DecodeError.truncated }
    defer { i += 1 }
    return b[i]
}
private func readBE16(_ b: [UInt8], _ i: inout Int) throws -> UInt16 {
    guard i + 2 <= b.count else { throw MsgPackValue.DecodeError.truncated }
    defer { i += 2 }
    return UInt16(b[i]) << 8 | UInt16(b[i + 1])
}
private func readBE32(_ b: [UInt8], _ i: inout Int) throws -> UInt32 {
    guard i + 4 <= b.count else { throw MsgPackValue.DecodeError.truncated }
    defer { i += 4 }
    return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}
private func readBE64(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
    guard i + 8 <= b.count else { throw MsgPackValue.DecodeError.truncated }
    defer { i += 8 }
    var v: UInt64 = 0
    for k in 0..<8 { v = v << 8 | UInt64(b[i + k]) }
    return v
}
