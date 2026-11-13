// PaxPackVerifier.swift
// PaxPack 簽名工具鏈包（格式 v1）的 App 端驗證器。
// 權威定義見格式規格 paxpack-format-spec-v1.md：本檔案逐條實作 §8
// 驗證端契約（步驟順序與錯誤分類與規格原文一致），Mach-O 正規化
// 雜湊逐條實作 §6，footer 與簽名依 §7。任一步失敗即整包拒絕：
// 不解包安裝、不更新任何狀態（含防回滾下限）。
import Foundation
import CryptoKit
import Security
import Compression

// MARK: - 信任根

enum PaxPackTrustRoot {
    /// 正式發行公鑰：P-256 未壓縮點（65 byte），key ID d3ff4e5796b0c8d9。
    /// 對應私鑰只存發行端，永不進倉庫、永不進 App。
    static let officialPublicKeyHex =
        "04cee38d707fa0312701ba4420238f157ceb916c" +
        "7d9db20b37da5d2071fff7b27be0cf4a2b150bd4" +
        "2f8a3090d4e0740ad0b2b7af8b87e39ec8869035" +
        "a02bac92a8"
    static var officialPublicKeyRaw: Data {
        Data(paxHexString: officialPublicKeyHex) ?? Data()
    }
}

// MARK: - 錯誤分類（規格 §8，字面值即對外回報碼）

enum PaxPackErrorCode: String {
    case format = "ERR_FORMAT"
    case archiveSignature = "ERR_ARCHIVE_SIGNATURE"
    case path = "ERR_PATH"
    case manifest = "ERR_MANIFEST"
    case kind = "ERR_KIND"
    case appVersion = "ERR_APP_VERSION"
    case rollback = "ERR_ROLLBACK"
    case listSignature = "ERR_LIST_SIGNATURE"
    case macho = "ERR_MACHO"
    case entryMismatch = "ERR_ENTRY_MISMATCH"
    case floorStore = "ERR_FLOOR_STORE"
}

struct PaxPackError: Error, LocalizedError, CustomStringConvertible {
    let code: PaxPackErrorCode
    let detail: String
    init(_ code: PaxPackErrorCode, _ detail: String) {
        self.code = code
        self.detail = detail
    }
    var description: String { "\(code.rawValue): \(detail)" }
    var errorDescription: String? { description }
}

// MARK: - manifest（規格 §4）

struct PaxPackManifest {
    let formatVersion: Int
    let packageID: String
    let name: String
    let version: String
    let securityEpoch: Int
    let minAppVersion: String
    let payloadKind: String
    let payloadDescription: String?
}

/// 驗證全數通過的產物：payload 已解到暫存區（不含 PXFileList.plist），
/// 安裝端把內容換入安裝槽後必須呼叫 commitFloor；stagingURL 的
/// 清理由呼叫端負責。
struct PaxPackVerifiedPackage {
    let manifest: PaxPackManifest
    let stagingURL: URL
    let entryCount: Int
}

// MARK: - 基礎工具（hex、域字串、雜湊串流）

extension Data {
    init?(paxHexString: String) {
        let s = paxHexString
        guard s.count % 2 == 0 else { return nil }
        var out = Data()
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
    var paxHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// 規格 §2 域字串（ASCII + NUL 結尾，逐字使用）
enum PaxPackDomain {
    static let archive = Data("PaxPack/archive#1".utf8) + Data([0])
    static let fileList = Data("PaxPack/filelist#1".utf8) + Data([0])
    static let macho = Data("PaxPack/macho#1".utf8) + Data([0])
    static let fat = Data("PaxPack/fat#1".utf8) + Data([0])
    static let file = Data("PaxPack/file#1".utf8) + Data([0])
    static let dir = Data("PaxPack/dir#1".utf8) + Data([0])
    static let link = Data("PaxPack/link#1".utf8) + Data([0])
}

/// SHA-256 串流：域字串開頭，其餘元件逐一以 frame 包裝（規格 §5）。
final class PaxPackDigest {
    private var hasher = SHA256()
    func update(_ data: Data) { hasher.update(data: data) }
    func update(domain: Data) { hasher.update(data: domain) }
    /// frame(b)：先寫 len(b) 的 8-byte 小端，再寫 b 本體。
    func frame(_ data: Data) {
        framePrefix(length: data.count)
        hasher.update(data: data)
    }
    func framePrefix(length: Int) {
        var v = UInt64(length).littleEndian
        hasher.update(data: Data(bytes: &v, count: 8))
    }
    func finalizeData() -> Data { Data(hasher.finalize()) }
    func finalizeHex() -> String { finalizeData().paxHexString }
}

func paxFrameDigest(domain: Data, chunks: [Data]) -> Data {
    let d = PaxPackDigest()
    d.update(domain: domain)
    for c in chunks { d.frame(c) }
    return d.finalizeData()
}

// MARK: - 防回滾下限儲存（規格 §8 第 5、8 步）

protocol PaxPackFloorStore {
    /// 已裝下限；無紀錄回 0。
    func floor(for packageID: String) -> Int
    /// 抬升下限；寫入失敗必須 throw PaxPackError(.floorStore)。
    func commitFloor(_ epoch: Int, for packageID: String) throws
}

/// 正式儲存：Keychain，鍵名 paxpack.floor.<PXPackageID>（規格 §8）。
struct KeychainPaxPackFloorStore: PaxPackFloorStore {
    private let service = "com.paxidx.paxpack"
    private func account(_ packageID: String) -> String {
        "paxpack.floor.\(packageID)"
    }
    func floor(for packageID: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(packageID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              let value = Int(text) else { return 0 }
        return value
    }
    func commitFloor(_ epoch: Int, for packageID: String) throws {
        let data = Data(String(epoch).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(packageID),
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary,
                                   update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw PaxPackError(.floorStore,
                               "Keychain floor write failed (OSStatus \(status))")
        }
    }
}

/// 測試用記憶體儲存（CI 向量測試使用，不進正式路徑）。
final class MemoryPaxPackFloorStore: PaxPackFloorStore {
    var floors: [String: Int] = [:]
    func floor(for packageID: String) -> Int { floors[packageID] ?? 0 }
    func commitFloor(_ epoch: Int, for packageID: String) throws {
        floors[packageID] = epoch
    }
}

// MARK: - ECDSA P-256 驗簽（raw r‖s 與 DER 互換依規格 §7）

enum PaxPackCrypto {
    static func rawToDER(_ raw: Data) -> Data {
        func encodeInteger(_ bytes: Data) -> Data {
            var b = [UInt8](bytes)
            while b.count > 1 && b[0] == 0 { b.removeFirst() }
            if b.isEmpty { b = [0] }
            if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
            return Data([0x02, UInt8(b.count)] + b)
        }
        let body = encodeInteger(raw.prefix(32)) + encodeInteger(raw.suffix(32))
        return Data([0x30, UInt8(body.count)]) + body
    }

    /// 對預先算好的 SHA-256 摘要驗 raw 簽名。
    static func verifyDigest(publicKeyRaw: Data, digest: Data,
                             rawSignature: Data) -> Bool {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(publicKeyRaw as CFData,
                                             attrs as CFDictionary,
                                             &error) else { return false }
        return SecKeyVerifySignature(
            key, .ecdsaSignatureDigestX962SHA256,
            digest as CFData, rawToDER(rawSignature) as CFData, &error)
    }
}

// MARK: - 位元組讀取小工具（小端／大端）

func paxU32LE(_ d: Data, _ off: Int) -> UInt32 {
    UInt32(d[off]) | UInt32(d[off + 1]) << 8 |
        UInt32(d[off + 2]) << 16 | UInt32(d[off + 3]) << 24
}
func paxU16LE(_ d: Data, _ off: Int) -> UInt16 {
    UInt16(d[off]) | UInt16(d[off + 1]) << 8
}
func paxU64LE(_ d: Data, _ off: Int) -> UInt64 {
    UInt64(paxU32LE(d, off)) | UInt64(paxU32LE(d, off + 4)) << 32
}
func paxU32BE(_ d: Data, _ off: Int) -> UInt32 {
    UInt32(d[off]) << 24 | UInt32(d[off + 1]) << 16 |
        UInt32(d[off + 2]) << 8 | UInt32(d[off + 3])
}
func paxU64Bytes(_ v: UInt64) -> Data {
    var x = v.littleEndian
    return Data(bytes: &x, count: 8)
}
func paxU32Bytes(_ v: UInt32) -> Data {
    var x = v.littleEndian
    return Data(bytes: &x, count: 4)
}

// MARK: - Mach-O 正規化雜湊（規格 §6；與打包端 paxpack.py 逐條對應）

enum PaxPackMachO {
    enum Kind { case thin64, fat, unsupported, notMachO }

    static func kind(ofMagicBytes b: Data) -> Kind {
        guard b.count >= 4 else { return .notMachO }
        let le = paxU32LE(b, 0)
        if le == 0xFEEDFACF { return .thin64 }
        let raw = [UInt8](b.prefix(4))
        if raw == [0xCA, 0xFE, 0xBA, 0xBE] || raw == [0xCA, 0xFE, 0xBA, 0xBF] {
            return .fat
        }
        if [0xFEEDFACE, 0xCEFAEDFE, 0xCFFAEDFE,
            0xCAFEBABE, 0xCAFEBABF].contains(le) { return .unsupported }
        return .notMachO
    }

    /// 條目分類（與打包端 macho_state 逐字一致，規格 §6.1 分類
    /// 規則）：回 .thin64／.fat 表示已合 §6.1 簽名資格、按 §6 計
    /// 雜湊；缺簽名的 Mach-O 候選、fat 包非 Mach-O 切片等一律回
    /// .notMachO 按一般檔逐字節計；32-bit／大端回 .unsupported。
    static func classify(fileHandle: FileHandle, length: Int) -> Kind {
        guard length >= 4 else { return .notMachO }
        fileHandle.seek(toFileOffset: 0)
        let head = fileHandle.readData(ofLength: 4)
        switch kind(ofMagicBytes: head) {
        case .unsupported:
            return .unsupported
        case .notMachO:
            return .notMachO
        case .thin64:
            return sliceHasSingleSignature(fileHandle: fileHandle,
                                           base: 0, length: length)
                ? .thin64 : .notMachO
        case .fat:
            guard length >= 8 else { return .notMachO }
            fileHandle.seek(toFileOffset: 4)
            let nb = fileHandle.readData(ofLength: 4)
            guard nb.count == 4 else { return .notMachO }
            let narch = Int(paxU32BE(nb, 0))
            guard narch >= 1, narch <= 16 else { return .notMachO }
            var off = 8
            for _ in 0..<narch {
                guard off + 20 <= length else { return .notMachO }
                fileHandle.seek(toFileOffset: UInt64(off))
                let e = fileHandle.readData(ofLength: 20)
                guard e.count == 20 else { return .notMachO }
                let soff = Int(paxU32BE(e, 8))
                let ssize = Int(paxU32BE(e, 12))
                guard ssize >= 32, soff + ssize <= length else {
                    return .notMachO
                }
                fileHandle.seek(toFileOffset: UInt64(soff))
                let sm = fileHandle.readData(ofLength: 4)
                guard sm.count == 4,
                      paxU32LE(sm, 0) == 0xFEEDFACF,
                      sliceHasSingleSignature(fileHandle: fileHandle,
                                              base: soff, length: ssize)
                else { return .notMachO }
                off += 20
            }
            return .fat
        }
    }

    /// 切片是否合 §6.1 簽名資格：命令區格式良好且恰有一條
    /// LC_CODE_SIGNATURE（cmdsize 16、dataoff 在命令區尾與檔尾之間）。
    private static func sliceHasSingleSignature(
        fileHandle: FileHandle, base: Int, length: Int) -> Bool {
        guard length >= 32 else { return false }
        fileHandle.seek(toFileOffset: UInt64(base))
        let header = fileHandle.readData(ofLength: 32)
        guard header.count == 32,
              paxU32LE(header, 0) == 0xFEEDFACF else { return false }
        let ncmds = Int(paxU32LE(header, 16))
        let sizeofcmds = Int(paxU32LE(header, 20))
        guard ncmds >= 1, sizeofcmds <= length - 32,
              sizeofcmds <= (1 << 24) else { return false }
        var off = 32
        let end = 32 + sizeofcmds
        var sigCount = 0
        var sigOK = false
        for _ in 0..<ncmds {
            guard end - off >= 8 else { return false }
            fileHandle.seek(toFileOffset: UInt64(base + off))
            let hb = fileHandle.readData(ofLength: 8)
            guard hb.count == 8 else { return false }
            let cmd = paxU32LE(hb, 0)
            let size = Int(paxU32LE(hb, 4))
            guard size >= 8, size % 8 == 0, size <= end - off else {
                return false
            }
            if cmd == 0x19 {  // LC_SEGMENT_64 的 nsects 界（同 §6.1）
                guard size >= 72 else { return false }
                fileHandle.seek(toFileOffset: UInt64(base + off + 64))
                let ns = fileHandle.readData(ofLength: 4)
                guard ns.count == 4,
                      Int(paxU32LE(ns, 0)) <= (size - 72) / 80 else {
                    return false
                }
            }
            if cmd == 0x1D {  // LC_CODE_SIGNATURE
                sigCount += 1
                fileHandle.seek(toFileOffset: UInt64(base + off + 8))
                let db = fileHandle.readData(ofLength: 4)
                guard db.count == 4 else { return false }
                let dataoff = Int(paxU32LE(db, 0))
                sigOK = size == 16 && dataoff >= end && dataoff <= length
            }
            off += size
        }
        guard off == end else { return false }
        return sigCount == 1 && sigOK
    }

    /// 隨機讀取介面：(offset, count) → 恰 count byte，越界即 throw。
    typealias Reader = (Int, Int) throws -> Data

    static func digest(data: Data) throws -> Data {
        try digest(length: data.count) { off, n in
            guard off >= 0, n >= 0, off + n <= data.count else {
                throw PaxPackError(.macho, "read out of bounds")
            }
            return data.subdata(in: off..<(off + n))
        }
    }

    static func digest(fileHandle: FileHandle, length: Int) throws -> Data {
        try digest(length: length) { off, n in
            fileHandle.seek(toFileOffset: UInt64(off))
            let d = fileHandle.readData(ofLength: n)
            guard d.count == n else {
                throw PaxPackError(.macho, "short read")
            }
            return d
        }
    }

    static func digest(length: Int, read: Reader) throws -> Data {
        let head = try read(0, min(4, length))
        switch kind(ofMagicBytes: head) {
        case .thin64:
            return try thinDigest(length: length, read: read)
        case .fat:
            return try fatDigest(length: length, read: read)
        default:
            throw PaxPackError(.macho,
                               "unsupported Mach-O (32-bit or big-endian)")
        }
    }

    private struct LoadCommand {
        let cmd: UInt32
        let bytes: Data
    }

    /// thin 切片正規化雜湊（規格 §6.2／§6.3）。
    static func thinDigest(length: Int, read: Reader) throws -> Data {
        guard length >= 32 else {
            throw PaxPackError(.macho, "not a 64-bit Mach-O")
        }
        let header = try read(0, 32)
        guard paxU32LE(header, 0) == 0xFEEDFACF else {
            throw PaxPackError(.macho, "not a 64-bit Mach-O")
        }
        let ncmds = Int(paxU32LE(header, 16))
        let sizeofcmds = Int(paxU32LE(header, 20))
        guard ncmds >= 1, sizeofcmds <= length - 32,
              sizeofcmds <= (1 << 24) else {
            throw PaxPackError(.macho, "malformed load commands")
        }
        var cmds: [LoadCommand] = []
        var off = 32
        let end = 32 + sizeofcmds
        for _ in 0..<ncmds {
            guard end - off >= 8 else {
                throw PaxPackError(.macho, "malformed load commands")
            }
            let hb = try read(off, 8)
            let cmd = paxU32LE(hb, 0)
            let size = Int(paxU32LE(hb, 4))
            guard size >= 8, size % 8 == 0, size <= end - off else {
                throw PaxPackError(.macho, "malformed load commands")
            }
            let bytes = try read(off, size)
            if cmd == 0x19 {  // LC_SEGMENT_64
                guard size >= 72,
                      Int(paxU32LE(bytes, 64)) <= (size - 72) / 80 else {
                    throw PaxPackError(.macho, "malformed segment")
                }
            }
            cmds.append(LoadCommand(cmd: cmd, bytes: bytes))
            off += size
        }
        guard off == end else {
            throw PaxPackError(.macho, "malformed load commands")
        }
        // §6.1 第 3 條：恰一條 LC_CODE_SIGNATURE、cmdsize 16、範圍合法
        let sigs = cmds.filter { $0.cmd == 0x1D }
        guard sigs.count == 1 else {
            throw PaxPackError(.macho, sigs.isEmpty
                ? "Mach-O must have exactly one LC_CODE_SIGNATURE"
                : "more than one code signature")
        }
        guard sigs[0].bytes.count == 16 else {
            throw PaxPackError(.macho, "malformed LC_CODE_SIGNATURE")
        }
        let dataoff = Int(paxU32LE(sigs[0].bytes, 8))
        guard dataoff >= end, dataoff <= length else {
            throw PaxPackError(.macho, "code signature lies outside the file")
        }
        // code 起點（規格 §6.2 定義）
        var start = dataoff
        for c in cmds where c.cmd == 0x19 {
            let b = c.bytes
            let fileoff = paxU64LE(b, 40)
            let filesize = paxU64LE(b, 48)
            if fileoff > 0 && filesize > 0 {
                start = min(start, Int(fileoff))
            }
            let nsects = Int(paxU32LE(b, 64))
            for j in 0..<nsects {
                let so = 72 + 80 * j
                let stype = paxU32LE(b, so + 64) & 0xFF
                let ssize = paxU64LE(b, so + 40)
                let soffset = paxU32LE(b, so + 48)
                if ![0x1, 0xC, 0x12].contains(stype),
                   ssize > 0, soffset > 0 {
                    start = min(start, Int(soffset))
                }
            }
        }
        // §6.1 第 4 條：命令區尾到 code 起點的空隙必須全零
        var pos = end
        while pos < start {
            let n = min(256 * 1024, start - pos)
            let chunk = try read(pos, n)
            if chunk.contains(where: { $0 != 0 }) {
                throw PaxPackError(
                    .macho, "non-zero padding between load commands and code")
            }
            pos += n
        }
        // 正規化串流（§6.2）
        let h = PaxPackDigest()
        h.update(domain: PaxPackDomain.macho)
        h.frame(header)
        h.frame(paxU64Bytes(UInt64(start)))
        h.frame(paxU64Bytes(UInt64(dataoff)))
        for c in cmds { h.frame(normalizedCommand(c)) }
        h.framePrefix(length: dataoff - start)
        pos = start
        while pos < dataoff {
            let n = min(1 << 20, dataoff - pos)
            h.update(try read(pos, n))
            pos += n
        }
        return h.finalizeData()
    }

    /// load command 副本改寫（規格 §6.3；只改送入雜湊的副本）
    private static func normalizedCommand(_ c: LoadCommand) -> Data {
        var raw = c.bytes
        let zeros8: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
        if c.cmd == 0x1D {  // LC_CODE_SIGNATURE：datasize（偏移 12）歸零
            raw.replaceSubrange(12..<16, with: [0, 0, 0, 0] as [UInt8])
        } else if c.cmd == 0x19 {  // LC_SEGMENT_64：按段名處理
            var nameBytes: [UInt8] = []
            for i in 8..<24 {
                let v = raw[i]
                if v == 0 { break }
                nameBytes.append(v)
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            if name == "__LINKEDIT" {
                raw.replaceSubrange(32..<40, with: zeros8)  // vmsize
                raw.replaceSubrange(48..<56, with: zeros8)  // filesize
            } else if name == "__PAGEZERO" {
                raw.replaceSubrange(24..<32, with: zeros8)  // vmaddr
                raw.replaceSubrange(32..<40, with: zeros8)  // vmsize
            }
        }
        return raw
    }

    /// fat 彙總雜湊（規格 §6.4；切片順序依 fat 標頭原序）
    static func fatDigest(length: Int, read: Reader) throws -> Data {
        guard length >= 8 else {
            throw PaxPackError(.macho, "truncated fat header")
        }
        let narch = Int(paxU32BE(try read(4, 4), 0))
        guard narch >= 1, narch <= 16 else {
            throw PaxPackError(.macho, "implausible fat arch count")
        }
        let h = PaxPackDigest()
        h.update(domain: PaxPackDomain.fat)
        var off = 8
        for _ in 0..<narch {
            guard off + 20 <= length else {
                throw PaxPackError(.macho, "truncated fat arch entry")
            }
            let e = try read(off, 20)
            let cputype = paxU32BE(e, 0)
            let cpusub = paxU32BE(e, 4)
            let soff = Int(paxU32BE(e, 8))
            let ssize = Int(paxU32BE(e, 12))
            off += 20
            guard soff + ssize <= length, ssize >= 32 else {
                throw PaxPackError(.macho, "fat slice out of bounds")
            }
            h.frame(paxU32Bytes(cputype))
            h.frame(paxU32Bytes(cpusub))
            let slice = try thinDigest(length: ssize) { o, n in
                try read(soff + o, n)
            }
            h.frame(slice)
        }
        return h.finalizeData()
    }
}

// MARK: - ZIP 讀取（中央目錄自解析 + raw deflate 解壓，不經外部解包器）

private final class PaxPackInflater {
    private var stream = compression_stream(
        dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
    private let dst: UnsafeMutablePointer<UInt8>
    private let dstCap = 1 << 18
    private(set) var ended = false

    init() throws {
        dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        let st = compression_stream_init(&stream,
                                         COMPRESSION_STREAM_DECODE,
                                         COMPRESSION_ZLIB)
        guard st == COMPRESSION_STATUS_OK else {
            dst.deallocate()
            throw PaxPackError(.format, "compression_stream_init failed")
        }
    }
    deinit {
        compression_stream_destroy(&stream)
        dst.deallocate()
    }

    func push(_ chunk: Data, isFinal: Bool, sink: (Data) -> Void) throws {
        let flags: compression_stream_flags = isFinal
            ? COMPRESSION_STREAM_FINALIZE
            : compression_stream_flags(rawValue: 0)
        if chunk.isEmpty {
            stream.src_ptr = UnsafePointer(dst)
            stream.src_size = 0
            try pump(flags: flags, sink: sink)
            return
        }
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.src_ptr = raw.baseAddress!
                .assumingMemoryBound(to: UInt8.self)
            stream.src_size = raw.count
            try pump(flags: isFinal
                        ? COMPRESSION_STREAM_FINALIZE
                        : compression_stream_flags(rawValue: 0),
                     sink: sink)
        }
    }

    private func pump(flags: compression_stream_flags,
                      sink: (Data) -> Void) throws {
        while true {
            stream.dst_ptr = dst
            stream.dst_size = dstCap
            let st = compression_stream_process(&stream, flags)
            let produced = dstCap - stream.dst_size
            if produced > 0 { sink(Data(bytes: dst, count: produced)) }
            if st == COMPRESSION_STATUS_ERROR {
                throw PaxPackError(.format, "deflate stream error")
            }
            if st == COMPRESSION_STATUS_END { ended = true; return }
            if stream.src_size == 0 { return }
            if produced == 0 { return }  // 無進展：交由上層以長度不符攔下
        }
    }
}

private struct PaxPackZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let externalAttrs: UInt32
    let localHeaderOffset: Int
    var mode: UInt32 { externalAttrs >> 16 }
}

private struct PaxPackZipReader {
    let handle: FileHandle
    let zipLength: Int

    func readExact(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= zipLength else {
            throw PaxPackError(.format, "zip read out of bounds")
        }
        handle.seek(toFileOffset: UInt64(offset))
        let d = handle.readData(ofLength: count)
        guard d.count == count else {
            throw PaxPackError(.format, "zip short read")
        }
        return d
    }

    func centralDirectory() throws -> [PaxPackZipEntry] {
        let tailLen = min(zipLength, 22 + 65535)
        let tail = try readExact(zipLength - tailLen, tailLen)
        var eocd: Int? = nil
        var i = tailLen - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B,
               tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                let commentLen = Int(paxU16LE(tail, i + 20))
                if i + 22 + commentLen == tailLen { eocd = i; break }
            }
            i -= 1
        }
        guard let e = eocd else {
            throw PaxPackError(.format, "end of central directory not found")
        }
        let total = Int(paxU16LE(tail, e + 10))
        let thisDiskCount = Int(paxU16LE(tail, e + 8))
        let cdSize = paxU32LE(tail, e + 12)
        let cdOffset = paxU32LE(tail, e + 16)
        guard paxU16LE(tail, e + 4) == 0, paxU16LE(tail, e + 6) == 0,
              thisDiskCount == total, total != 0xFFFF,
              cdSize != 0xFFFFFFFF, cdOffset != 0xFFFFFFFF,
              Int(cdOffset) + Int(cdSize) == zipLength - tailLen + e else {
            throw PaxPackError(.format, "unsupported or malformed EOCD")
        }
        var entries: [PaxPackZipEntry] = []
        var pos = Int(cdOffset)
        for _ in 0..<total {
            let h = try readExact(pos, 46)
            guard paxU32LE(h, 0) == 0x02014B50 else {
                throw PaxPackError(.format, "bad central directory header")
            }
            let flags = paxU16LE(h, 8)
            guard flags & 0x0001 == 0, flags & 0x0008 == 0 else {
                throw PaxPackError(
                    .format, "encrypted/descriptor entries unsupported")
            }
            let comp = paxU32LE(h, 20)
            let uncomp = paxU32LE(h, 24)
            let lho = paxU32LE(h, 42)
            guard comp != 0xFFFFFFFF, uncomp != 0xFFFFFFFF,
                  lho != 0xFFFFFFFF else {
                throw PaxPackError(.format, "ZIP64 unsupported")
            }
            guard paxU16LE(h, 34) == 0 else {
                throw PaxPackError(.format, "multi-disk zip unsupported")
            }
            let nlen = Int(paxU16LE(h, 28))
            let elen = Int(paxU16LE(h, 30))
            let clen = Int(paxU16LE(h, 32))
            let nameData = try readExact(pos + 46, nlen)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw PaxPackError(.format, "entry name is not UTF-8")
            }
            entries.append(PaxPackZipEntry(
                name: name, method: paxU16LE(h, 10),
                compressedSize: Int(comp), uncompressedSize: Int(uncomp),
                externalAttrs: paxU32LE(h, 38),
                localHeaderOffset: Int(lho)))
            pos += 46 + nlen + elen + clen
        }
        guard pos == Int(cdOffset) + Int(cdSize) else {
            throw PaxPackError(.format, "central directory size mismatch")
        }
        return entries
    }

    /// 把單一條目的未壓縮內容串流給 sink；回傳實際產出 byte 數。
    func streamEntry(_ e: PaxPackZipEntry,
                     sink: (Data) -> Void) throws -> Int {
        let lh = try readExact(e.localHeaderOffset, 30)
        guard paxU32LE(lh, 0) == 0x04034B50 else {
            throw PaxPackError(.format, "bad local header for \(e.name)")
        }
        let nlen = Int(paxU16LE(lh, 26))
        let elen = Int(paxU16LE(lh, 28))
        let dataStart = e.localHeaderOffset + 30 + nlen + elen
        guard dataStart + e.compressedSize <= zipLength else {
            throw PaxPackError(.format, "entry data out of bounds")
        }
        var produced = 0
        let counting: (Data) -> Void = { d in
            produced += d.count
            sink(d)
        }
        var remaining = e.compressedSize
        handle.seek(toFileOffset: UInt64(dataStart))
        switch e.method {
        case 0:
            while remaining > 0 {
                let n = min(remaining, 1 << 20)
                let chunk = handle.readData(ofLength: n)
                guard chunk.count == n else {
                    throw PaxPackError(.format, "entry short read")
                }
                counting(chunk)
                remaining -= n
            }
        case 8:
            let inflater = try PaxPackInflater()
            if remaining == 0 {
                try inflater.push(Data(), isFinal: true, sink: counting)
            }
            while remaining > 0 {
                let n = min(remaining, 1 << 20)
                let chunk = handle.readData(ofLength: n)
                guard chunk.count == n else {
                    throw PaxPackError(.format, "entry short read")
                }
                remaining -= n
                try inflater.push(chunk, isFinal: remaining == 0,
                                  sink: counting)
            }
            guard inflater.ended else {
                throw PaxPackError(.format,
                                   "deflate stream did not terminate")
            }
        default:
            throw PaxPackError(.format,
                               "unsupported compression method \(e.method)")
        }
        return produced
    }

    func entryData(_ e: PaxPackZipEntry, maxBytes: Int) throws -> Data {
        guard e.uncompressedSize <= maxBytes else {
            throw PaxPackError(.format, "entry too large: \(e.name)")
        }
        var out = Data()
        out.reserveCapacity(e.uncompressedSize)
        let n = try streamEntry(e) { out.append($0) }
        guard n == e.uncompressedSize else {
            throw PaxPackError(.format, "entry size mismatch: \(e.name)")
        }
        return out
    }
}

// MARK: - 清單標準形序列化（規格 §5：複現 plistlib XML 的逐字節形式）

enum PaxPackCanonicalPlist {
    static func serialize(_ root: Any) throws -> Data {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        s += "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        s += "<plist version=\"1.0\">\n"
        try write(root, depth: 0, into: &s)
        s += "</plist>\n"
        return Data(s.utf8)
    }

    private static func escape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func write(_ v: Any, depth: Int,
                              into s: inout String) throws {
        let ind = String(repeating: "\t", count: depth)
        switch v {
        case let d as [String: Any]:
            if d.isEmpty { s += "\(ind)<dict/>\n"; return }
            s += "\(ind)<dict>\n"
            for k in d.keys.sorted() {
                s += "\(ind)\t<key>\(escape(k))</key>\n"
                try write(d[k]!, depth: depth + 1, into: &s)
            }
            s += "\(ind)</dict>\n"
        case let a as [Any]:
            if a.isEmpty { s += "\(ind)<array/>\n"; return }
            s += "\(ind)<array>\n"
            for el in a { try write(el, depth: depth + 1, into: &s) }
            s += "\(ind)</array>\n"
        case let str as String:
            s += "\(ind)<string>\(escape(str))</string>\n"
        case let n as NSNumber:
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else {
                throw PaxPackError(.listSignature,
                                   "bool in canonical list")
            }
            s += "\(ind)<integer>\(n.int64Value)</integer>\n"
        default:
            throw PaxPackError(.listSignature,
                               "unsupported value in list canonicalization")
        }
    }
}

// MARK: - plist 欄位與路徑驗證小工具

func paxPlistInt(_ v: Any?) -> Int? {
    guard let n = v as? NSNumber,
          CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return Int(exactly: n.int64Value)
}

/// 規格 §4：反向 DNS 識別碼（[A-Za-z0-9._-]+、至少兩段、段不可空）。
func paxIdentifierValid(_ s: String) -> Bool {
    guard !s.isEmpty, s.count <= 255 else { return false }
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
            "abcdefghijklmnopqrstuvwxyz0123456789._-")
    guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
        return false
    }
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
}

/// 語意版本比較：a 是否嚴格大於 b（逐段數字比較、缺段補 0）。
func paxSemverGreater(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

func paxTopComponent(_ name: String) -> String {
    if let idx = name.firstIndex(of: "/") {
        return String(name[name.startIndex..<idx])
    }
    return name
}

/// 規格 §3 第 2 條：相對路徑、禁止空段／`..`／反斜線。
func paxValidateRelPath(_ rel: String, entryName: String) throws {
    guard !rel.isEmpty, !rel.contains("\\") else {
        throw PaxPackError(.path, "bad entry path: \(entryName)")
    }
    for seg in rel.split(separator: "/", omittingEmptySubsequences: false) {
        guard !seg.isEmpty, seg != ".." else {
            throw PaxPackError(.path, "bad entry path: \(entryName)")
        }
    }
}

/// 規格 §3 第 3 條：symlink 目標必須相對且詞法解析後不逃出包根。
func paxValidateSymlink(rel: String, target: String) throws {
    if target.hasPrefix("/") {
        throw PaxPackError(.path, "symlink escapes package: \(rel)")
    }
    var stack = rel.split(separator: "/").dropLast().map(String.init)
    for part in target.split(separator: "/",
                             omittingEmptySubsequences: false) {
        switch part {
        case "", ".":
            continue
        case "..":
            if stack.isEmpty {
                throw PaxPackError(.path,
                                   "symlink escapes package: \(rel)")
            }
            stack.removeLast()
        default:
            stack.append(String(part))
        }
    }
}

// MARK: - 驗證器主體（規格 §8 步驟 1–8）

struct PaxPackVerifier {
    let publicKeyRaw: Data
    let appVersion: String
    let floorStore: PaxPackFloorStore

    init(publicKeyRaw: Data = PaxPackTrustRoot.officialPublicKeyRaw,
         appVersion: String = (Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String) ?? "0.0.0",
         floorStore: PaxPackFloorStore = KeychainPaxPackFloorStore()) {
        self.publicKeyRaw = publicKeyRaw
        self.appVersion = appVersion
        self.floorStore = floorStore
    }

    /// §8 第 8 步後段：安裝端把 payload 換入安裝槽成功後呼叫；
    /// 寫入失敗 throw ERR_FLOOR_STORE，安裝端必須回滾本次安裝。
    func commitFloor(for manifest: PaxPackManifest) throws {
        try floorStore.commitFloor(manifest.securityEpoch,
                                   for: manifest.packageID)
    }

    func verifyAndStage(packageAt url: URL,
                        expectedKind: String)
        throws -> PaxPackVerifiedPackage {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = Int(handle.seekToEndOfFile())

        // 步驟 1：切 footer
        guard fileSize >= 81 else {
            throw PaxPackError(.format, "file shorter than footer")
        }
        handle.seek(toFileOffset: UInt64(fileSize - 81))
        let footer = handle.readData(ofLength: 81)
        guard footer.count == 81,
              footer.prefix(8).elementsEqual("PXPK0001".utf8) else {
            throw PaxPackError(.format, "bad footer magic")
        }
        let zipLen64 = paxU64LE(footer, 8)
        guard footer[16] == 1, zipLen64 + 81 == UInt64(fileSize) else {
            throw PaxPackError(.format, "bad footer")
        }
        let zipLen = Int(zipLen64)
        let rawSig = footer.subdata(in: 17..<81)

        // 步驟 2：驗封存簽名（解 ZIP 之前）
        let archiveDigest = PaxPackDigest()
        archiveDigest.update(domain: PaxPackDomain.archive)
        handle.seek(toFileOffset: 0)
        var remaining = zipLen
        while remaining > 0 {
            let n = min(remaining, 1 << 20)
            let chunk = handle.readData(ofLength: n)
            guard chunk.count == n else {
                throw PaxPackError(.format, "short read")
            }
            archiveDigest.update(chunk)
            remaining -= n
        }
        guard PaxPackCrypto.verifyDigest(
            publicKeyRaw: publicKeyRaw,
            digest: archiveDigest.finalizeData(),
            rawSignature: rawSig) else {
            throw PaxPackError(.archiveSignature,
                               "archive signature does not verify")
        }

        // 步驟 3：解 ZIP 結構與路徑安全
        let reader = PaxPackZipReader(handle: handle, zipLength: zipLen)
        let entries = try reader.centralDirectory()
        var seenNames = Set<String>()
        for e in entries {
            guard seenNames.insert(e.name).inserted else {
                throw PaxPackError(.path, "duplicate entry \(e.name)")
            }
        }
        let contentNames = entries.map(\.name).filter {
            !$0.isEmpty && !$0.hasPrefix("__MACOSX/")
        }
        let tops = Set(contentNames.map(paxTopComponent))
        guard tops.count == 1, let top = tops.first, !top.isEmpty else {
            throw PaxPackError(
                .format, "package must hold exactly one top-level directory")
        }
        let prefix = top + "/"
        var relByName: [String: String] = [:]
        for e in entries {
            if e.name == prefix { continue }
            guard e.name.hasPrefix(prefix) else {
                throw PaxPackError(.path,
                                   "entry outside top dir: \(e.name)")
            }
            var rel = String(e.name.dropFirst(prefix.count))
            if rel.hasSuffix("/") { rel = String(rel.dropLast()) }
            try paxValidateRelPath(rel, entryName: e.name)
            if relByName.values.contains(rel) {
                throw PaxPackError(.path, "duplicate entry \(rel)")
            }
            relByName[e.name] = rel
        }

        // 步驟 4：讀 manifest（類別與最低 App 版本在此判）
        guard let manifestEntry = entries.first(
            where: { $0.name == prefix + "manifest.plist" }) else {
            throw PaxPackError(.manifest, "manifest.plist missing")
        }
        let manifestData = try reader.entryData(manifestEntry,
                                                maxBytes: 16 << 20)
        let manifest = try parseManifest(manifestData)
        guard manifest.payloadKind == expectedKind else {
            throw PaxPackError(
                .kind, "payload kind \(manifest.payloadKind) not accepted")
        }
        if paxSemverGreater(manifest.minAppVersion, than: appVersion) {
            throw PaxPackError(
                .appVersion,
                "package requires app \(manifest.minAppVersion), " +
                "app is \(appVersion)")
        }

        // 步驟 5：防回滾
        let floor = floorStore.floor(for: manifest.packageID)
        guard manifest.securityEpoch >= floor else {
            throw PaxPackError(
                .rollback,
                "package epoch \(manifest.securityEpoch) " +
                "< installed floor \(floor)")
        }

        // 步驟 6：驗清單簽名與 manifest 一致性
        guard let listEntry = entries.first(
            where: { $0.name == prefix + "PXFileList.plist" }) else {
            throw PaxPackError(.listSignature, "PXFileList.plist missing")
        }
        let listData = try reader.entryData(listEntry,
                                            maxBytes: 256 << 20)
        let listObj: Any
        do {
            listObj = try PropertyListSerialization.propertyList(
                from: listData, options: [], format: nil)
        } catch {
            throw PaxPackError(.listSignature, "file list is not a plist")
        }
        guard var listDict = listObj as? [String: Any] else {
            throw PaxPackError(.listSignature, "file list is not a dict")
        }
        guard let listSig = listDict.removeValue(
                forKey: "pxListSignature") as? Data,
              listSig.count == 64 else {
            throw PaxPackError(.listSignature,
                               "missing/invalid list signature")
        }
        let canonical = try PaxPackCanonicalPlist.serialize(listDict)
        let listDigest = PaxPackDigest()
        listDigest.update(domain: PaxPackDomain.fileList)
        listDigest.update(canonical)
        guard PaxPackCrypto.verifyDigest(
            publicKeyRaw: publicKeyRaw,
            digest: listDigest.finalizeData(),
            rawSignature: listSig) else {
            throw PaxPackError(.listSignature,
                               "list signature does not verify")
        }
        guard (listDict["PXPackageID"] as? String) == manifest.packageID,
              paxPlistInt(listDict["PXSecurityEpoch"]) ==
                manifest.securityEpoch else {
            throw PaxPackError(.listSignature,
                               "list/manifest id or epoch mismatch")
        }
        guard let rawEntries = listDict["entries"] as? [Any] else {
            throw PaxPackError(.listSignature, "entries missing")
        }
        var listed: [String: (kind: String, size: Int, hex: String)] = [:]
        for element in rawEntries {
            guard let e = element as? [String: Any],
                  let path = e["path"] as? String,
                  let kind = e["kind"] as? String,
                  let size = paxPlistInt(e["size"]),
                  let sha = e["sha256"] as? String else {
                throw PaxPackError(.listSignature, "malformed list entry")
            }
            guard listed[path] == nil else {
                throw PaxPackError(.listSignature,
                                   "duplicate listed path \(path)")
            }
            listed[path] = (kind, size, sha)
        }

        // 步驟 7：逐條複驗（內容先落隔離區，全數通過才組裝暫存區）
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent(
            "PaxPackWork-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir,
                               withIntermediateDirectories: true)
        var stagingURL: URL? = nil
        var keepStaging = false
        defer {
            try? fm.removeItem(at: workDir)
            if !keepStaging, let s = stagingURL {
                try? fm.removeItem(at: s)
            }
        }
        var actual: [String: PaxPackActualEntry] = [:]
        do {
            var fileIndex = 0
            for e in entries {
                if e.name == listEntry.name { continue }
                guard let rel = relByName[e.name] else { continue }
                if e.name.hasSuffix("/") {
                    let hex = paxFrameDigest(
                        domain: PaxPackDomain.dir,
                        chunks: [Data(rel.utf8)]).paxHexString
                    actual[rel] = PaxPackActualEntry(
                        kind: "dir", size: 0, hex: hex,
                        quarantineFile: nil, linkTarget: nil, mode: e.mode)
                } else if e.mode & 0o170000 == 0o120000 {
                    let data = try reader.entryData(e, maxBytes: 1 << 20)
                    guard let target = String(data: data,
                                              encoding: .utf8) else {
                        throw PaxPackError(
                            .path, "symlink target not UTF-8: \(rel)")
                    }
                    try paxValidateSymlink(rel: rel, target: target)
                    let hex = paxFrameDigest(
                        domain: PaxPackDomain.link,
                        chunks: [Data(target.utf8)]).paxHexString
                    actual[rel] = PaxPackActualEntry(
                        kind: "link", size: target.utf8.count, hex: hex,
                        quarantineFile: nil, linkTarget: target,
                        mode: e.mode)
                } else {
                    let qf = workDir.appendingPathComponent(
                        "f\(fileIndex)")
                    fileIndex += 1
                    fm.createFile(atPath: qf.path, contents: nil)
                    let out = try FileHandle(forWritingTo: qf)
                    let hasher = PaxPackDigest()
                    hasher.update(domain: PaxPackDomain.file)
                    hasher.framePrefix(length: e.uncompressedSize)
                    let produced = try reader.streamEntry(e) { chunk in
                        hasher.update(chunk)
                        out.write(chunk)
                    }
                    try? out.close()
                    guard produced == e.uncompressedSize else {
                        throw PaxPackError(
                            .format, "entry size mismatch: \(rel)")
                    }
                    let qh = try FileHandle(forReadingFrom: qf)
                    let kind: String
                    let hex: String
                    switch PaxPackMachO.classify(fileHandle: qh,
                                                 length: produced) {
                    case .thin64, .fat:
                        kind = "macho"
                        hex = try PaxPackMachO.digest(
                            fileHandle: qh, length: produced).paxHexString
                    case .unsupported:
                        try? qh.close()
                        throw PaxPackError(.macho,
                                           "\(rel): unsupported Mach-O")
                    case .notMachO:
                        kind = "file"
                        hex = hasher.finalizeHex()
                    }
                    try? qh.close()
                    actual[rel] = PaxPackActualEntry(
                        kind: kind, size: produced, hex: hex,
                        quarantineFile: qf, linkTarget: nil, mode: e.mode)
                }
            }
        } catch let error as PaxPackError {
            throw error
        } catch {
            throw PaxPackError(.path,
                               "extraction failed: \(error)")
        }
        guard Set(actual.keys) == Set(listed.keys) else {
            let onlyZip = Set(actual.keys)
                .subtracting(listed.keys).sorted()
            let onlyList = Set(listed.keys)
                .subtracting(actual.keys).sorted()
            throw PaxPackError(
                .entryMismatch,
                "entry set differs (only-in-zip=\(onlyZip), " +
                "only-in-list=\(onlyList))")
        }
        for (path, want) in listed {
            let got = actual[path]!
            guard got.kind == want.kind, got.size == want.size,
                  got.hex == want.hex else {
                throw PaxPackError(.entryMismatch, path)
            }
        }

        // 步驟 8（前半）：組裝暫存區；換入安裝槽與下限提交由安裝端接續
        let stage = fm.temporaryDirectory.appendingPathComponent(
            "PaxPackStage-\(UUID().uuidString)", isDirectory: true)
        stagingURL = stage
        do {
            try fm.createDirectory(at: stage,
                                   withIntermediateDirectories: true)
            for rel in actual.keys.sorted() {
                let a = actual[rel]!
                let dest = stage.appendingPathComponent(rel)
                switch a.kind {
                case "dir":
                    try fm.createDirectory(
                        at: dest, withIntermediateDirectories: true)
                case "link":
                    try fm.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try fm.createSymbolicLink(
                        atPath: dest.path,
                        withDestinationPath: a.linkTarget!)
                default:
                    try fm.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try fm.moveItem(at: a.quarantineFile!, to: dest)
                    let perm = a.mode & 0o7777
                    if perm != 0 {
                        try? fm.setAttributes(
                            [.posixPermissions: Int(perm)],
                            ofItemAtPath: dest.path)
                    }
                }
            }
        } catch let error as PaxPackError {
            throw error
        } catch {
            throw PaxPackError(.path,
                               "staging failed: \(error)")
        }
        keepStaging = true
        return PaxPackVerifiedPackage(manifest: manifest,
                                      stagingURL: stage,
                                      entryCount: listed.count)
    }

    /// 規格 §4 欄位驗證（與打包端 _manifest_check 逐項對應）。
    private func parseManifest(_ data: Data) throws -> PaxPackManifest {
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        } catch {
            throw PaxPackError(.manifest, "manifest is not a plist")
        }
        guard let m = obj as? [String: Any] else {
            throw PaxPackError(.manifest, "manifest is not a dict")
        }
        guard paxPlistInt(m["PXFormatVersion"]) == 1 else {
            throw PaxPackError(.manifest,
                               "PXFormatVersion must be int 1")
        }
        guard let pid = m["PXPackageID"] as? String,
              paxIdentifierValid(pid) else {
            throw PaxPackError(.manifest, "PXPackageID invalid")
        }
        func reqStr(_ key: String) throws -> String {
            guard let s = m[key] as? String, !s.isEmpty else {
                throw PaxPackError(
                    .manifest, "\(key) must be a non-empty string")
            }
            return s
        }
        guard let epoch = paxPlistInt(m["PXSecurityEpoch"]),
              epoch >= 1 else {
            throw PaxPackError(.manifest,
                               "PXSecurityEpoch must be int >= 1")
        }
        return PaxPackManifest(
            formatVersion: 1,
            packageID: pid,
            name: try reqStr("PXName"),
            version: try reqStr("PXVersion"),
            securityEpoch: epoch,
            minAppVersion: try reqStr("PXMinAppVersion"),
            payloadKind: try reqStr("PXPayloadKind"),
            payloadDescription: m["PXPayloadDescription"] as? String)
    }
}

private struct PaxPackActualEntry {
    let kind: String
    let size: Int
    let hex: String
    let quarantineFile: URL?
    let linkTarget: String?
    let mode: UInt32
}
