import Foundation
import Compression

/// A minimal, dependency-free ZIP reader/writer.
///
/// Reading supports **stored (0)** and **deflate (8)** entries — deflate via the system Compression
/// framework (Apple's `.zlib` codec is raw DEFLATE, matching ZIP). Writing produces **stored-only**
/// archives (used by our exporter). This is intentionally small and defensive because it parses
/// untrusted community `.livewallpaper` files: every offset/length is bounds-checked and sizes are
/// capped. It is not a general-purpose ZIP library (no ZIP64, encryption, or multi-disk).
enum ZipArchive {

    enum ZipError: LocalizedError {
        case notAZip
        case corrupt(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notAZip: return "Not a valid .livewallpaper (ZIP) file."
            case let .corrupt(why): return "Corrupt archive: \(why)."
            case .tooLarge: return "Archive or an entry exceeds the size limit."
            }
        }
    }

    // Safety caps.
    private static let maxEntries = 4096
    private static let maxEntrySize = 256 * 1024 * 1024   // 256 MB uncompressed per file

    // Signatures.
    private static let eocdSig: UInt32 = 0x0605_4b50
    private static let centralSig: UInt32 = 0x0201_4b50
    private static let localSig: UInt32 = 0x0403_4b50

    // MARK: - Read

    /// Extract all entries into a `path → data` map. Directory entries are skipped.
    static func extract(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError.notAZip }

        let eocd = try findEOCD(bytes)
        let count = u16(bytes, eocd + 10)
        let cdOffset = Int(u32(bytes, eocd + 16))
        guard count <= maxEntries else { throw ZipError.tooLarge }
        guard cdOffset < bytes.count else { throw ZipError.corrupt("central dir offset") }

        var result: [String: Data] = [:]
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(bytes, p) == centralSig else {
                throw ZipError.corrupt("central header")
            }
            let method = u16(bytes, p + 10)
            let compSize = Int(u32(bytes, p + 20))
            let uncompSize = Int(u32(bytes, p + 24))
            let fnLen = Int(u16(bytes, p + 28))
            let extraLen = Int(u16(bytes, p + 30))
            let commentLen = Int(u16(bytes, p + 32))
            let localOffset = Int(u32(bytes, p + 42))
            guard p + 46 + fnLen <= bytes.count else { throw ZipError.corrupt("filename") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + fnLen)], as: UTF8.self)

            if !name.hasSuffix("/") {
                guard uncompSize <= maxEntrySize, compSize <= maxEntrySize else { throw ZipError.tooLarge }
                let payload = try readLocal(bytes, localOffset: localOffset, method: method,
                                            compSize: compSize, uncompSize: uncompSize)
                // Reject path traversal.
                guard !name.contains("..") && !name.hasPrefix("/") else {
                    throw ZipError.corrupt("unsafe path '\(name)'")
                }
                result[name] = payload
            }
            p += 46 + fnLen + extraLen + commentLen
        }
        return result
    }

    private static func findEOCD(_ bytes: [UInt8]) throws -> Int {
        // Scan backwards for the EOCD signature (comment may follow it, up to 64KB).
        let minStart = max(0, bytes.count - (22 + 65_536))
        var i = bytes.count - 22
        while i >= minStart {
            if u32(bytes, i) == eocdSig { return i }
            i -= 1
        }
        throw ZipError.notAZip
    }

    private static func readLocal(_ bytes: [UInt8], localOffset: Int, method: UInt16,
                                  compSize: Int, uncompSize: Int) throws -> Data {
        guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == localSig else {
            throw ZipError.corrupt("local header")
        }
        let fnLen = Int(u16(bytes, localOffset + 26))
        let extraLen = Int(u16(bytes, localOffset + 28))
        let start = localOffset + 30 + fnLen + extraLen
        guard start + compSize <= bytes.count else { throw ZipError.corrupt("entry data range") }
        let comp = Array(bytes[start..<(start + compSize)])

        switch method {
        case 0:
            return Data(comp)
        case 8:
            return try inflate(comp, expectedSize: uncompSize)
        default:
            throw ZipError.corrupt("unsupported compression method \(method)")
        }
    }

    private static func inflate(_ input: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var dst = [UInt8](repeating: 0, count: expectedSize)
        let written = input.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { out in
                compression_decode_buffer(out.baseAddress!, expectedSize,
                                          src.baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt("inflate size mismatch") }
        return Data(dst)
    }

    // MARK: - Write (stored only)

    /// Build a stored-only ZIP from `files` (path → data). Deterministic (sorted by path).
    static func archive(_ files: [String: Data]) -> Data {
        var out = Data()
        var central = Data()
        var localOffsets: [(name: String, offset: Int, crc: UInt32, size: Int)] = []

        for name in files.keys.sorted() {
            let payload = files[name]!
            let nameBytes = Array(name.utf8)
            let crc = crc32(payload)
            let offset = out.count

            // Local file header.
            out.append(le32(localSig))
            out.append(le16(20))            // version needed
            out.append(le16(0))             // flags
            out.append(le16(0))             // method: stored
            out.append(le16(0)); out.append(le16(0)) // time, date
            out.append(le32(crc))
            out.append(le32(UInt32(payload.count)))  // compressed size
            out.append(le32(UInt32(payload.count)))  // uncompressed size
            out.append(le16(UInt16(nameBytes.count)))
            out.append(le16(0))             // extra len
            out.append(contentsOf: nameBytes)
            out.append(payload)

            localOffsets.append((name, offset, crc, payload.count))
        }

        for e in localOffsets {
            let nameBytes = Array(e.name.utf8)
            central.append(le32(centralSig))
            central.append(le16(20))        // version made by
            central.append(le16(20))        // version needed
            central.append(le16(0))         // flags
            central.append(le16(0))         // method: stored
            central.append(le16(0)); central.append(le16(0)) // time, date
            central.append(le32(e.crc))
            central.append(le32(UInt32(e.size)))
            central.append(le32(UInt32(e.size)))
            central.append(le16(UInt16(nameBytes.count)))
            central.append(le16(0))         // extra
            central.append(le16(0))         // comment
            central.append(le16(0))         // disk start
            central.append(le16(0))         // internal attrs
            central.append(le32(0))         // external attrs
            central.append(le32(UInt32(e.offset)))
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = out.count
        out.append(central)

        // EOCD.
        out.append(le32(eocdSig))
        out.append(le16(0)); out.append(le16(0))  // disk numbers
        out.append(le16(UInt16(localOffsets.count)))
        out.append(le16(UInt16(localOffsets.count)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(UInt32(centralOffset)))
        out.append(le16(0))                        // comment len
        return out
    }

    // MARK: - Byte helpers

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    // MARK: - CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
