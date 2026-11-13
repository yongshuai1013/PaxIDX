// PaxPack 向量測試驅動（CI 專用，不進 App target）。
// 與 Sources/PaxIDX/PaxPackVerifier.swift 一起以 swiftc 編成命令列
// 工具，在 macOS runner 上驗證 App 端驗證器與打包端（Python）逐字
// 對版：§12 測試向量、六格不變性、整包正負測、防回滾語義。
// 用法：
//   selftest <fixtureDir>
//   verify <pkg> <pubHex|default> <floor> <kind> <appVersion>
//   macho-hash <file>
import Foundation
import CryptoKit

var passCount = 0
var failCount = 0

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        passCount += 1
        print("PASS \(name)")
    } else {
        failCount += 1
        print("FAIL \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }
}

func checkSoft(_ name: String, _ cond: Bool, _ detail: String = "") {
    print("\(cond ? "PASS" : "SOFT-FAIL") \(name)" +
          "\(detail.isEmpty ? "" : "  [\(detail)]")")
}

/// 試驗鑰公鑰（第一期試水鑰，key ID 4c7a6a7319a72987；只用於向量）。
let trialPublicKeyHex =
    "04b4a1d39b644b3fc28e6b7b8007031eff535160" +
    "569d310caa97a48d7446733df52a8fd9752d5836" +
    "52c848879470f307a7dd9c3439851fd196821a5f" +
    "8f3cc98e9a"

func makeVerifier(pubHex: String, floor: Int,
                  packageID: String, appVersion: String)
    -> PaxPackVerifier {
    let store = MemoryPaxPackFloorStore()
    if floor > 0 { store.floors[packageID] = floor }
    return PaxPackVerifier(
        publicKeyRaw: Data(paxHexString: pubHex)!,
        appVersion: appVersion, floorStore: store)
}

/// 期望驗證成功；成功回傳 manifest（並清掉暫存區）。
func expectOK(_ name: String, _ v: PaxPackVerifier, _ pkg: URL,
              _ kind: String) -> PaxPackManifest? {
    do {
        let r = try v.verifyAndStage(packageAt: pkg, expectedKind: kind)
        defer { try? FileManager.default.removeItem(at: r.stagingURL) }
        check(name, true)
        return r.manifest
    } catch {
        check(name, false, "\(error)")
        return nil
    }
}

/// 期望驗證失敗且錯誤碼相符。
func expectErr(_ name: String, _ v: PaxPackVerifier, _ pkg: URL,
               _ kind: String, _ code: PaxPackErrorCode) {
    do {
        let r = try v.verifyAndStage(packageAt: pkg, expectedKind: kind)
        try? FileManager.default.removeItem(at: r.stagingURL)
        check(name, false, "verified but should have failed")
    } catch let e as PaxPackError {
        check(name, e.code == code, "got \(e.code.rawValue), want \(code.rawValue)")
    } catch {
        check(name, false, "non-PaxPack error: \(error)")
    }
}

/// thin Mach-O 版面小解析（給六格實驗定位用；只找簽名命令與 LINKEDIT）
func thinLayout(_ d: Data)
    -> (sigCmdOff: Int, dataoff: Int, linkeditVmsizeOff: Int)? {
    guard d.count >= 32, paxU32LE(d, 0) == 0xFEEDFACF else { return nil }
    let ncmds = Int(paxU32LE(d, 16))
    var off = 32
    var sig: (Int, Int)? = nil
    var leVmsize: Int? = nil
    for _ in 0..<ncmds {
        let cmd = paxU32LE(d, off)
        let size = Int(paxU32LE(d, off + 4))
        if cmd == 0x1D {
            sig = (off, Int(paxU32LE(d, off + 8)))
        }
        if cmd == 0x19 {
            var nb: [UInt8] = []
            for i in 8..<24 {
                let v = d[off + i]
                if v == 0 { break }
                nb.append(v)
            }
            if String(decoding: nb, as: UTF8.self) == "__LINKEDIT" {
                leVmsize = off + 32
            }
        }
        off += size
    }
    guard let s = sig, let lv = leVmsize else { return nil }
    return (s.0, s.1, lv)
}

func machoHex(_ d: Data) -> String? {
    (try? PaxPackMachO.digest(data: d))?.paxHexString
}

func runSelftest(_ fixtureDir: String) {
    let dir = URL(fileURLWithPath: fixtureDir)
    let trialPkg = dir.appendingPathComponent("trial-a.pxpk")
    let officialPkg = dir.appendingPathComponent("official-sample.pxpk")
    let trialID = "com.paxidx.trial-toolchain"

    // 內嵌正式公鑰指紋（抓抄寫錯誤）
    let keyID = PaxPackTrustRoot.officialPublicKeyRaw.paxHexString
    let digest = SHA256.hash(data: PaxPackTrustRoot.officialPublicKeyRaw)
    let kid = digest.map { String(format: "%02x", $0) }
        .joined().prefix(16)
    check("embedded key id == d3ff4e5796b0c8d9",
          String(kid) == "d3ff4e5796b0c8d9", "got \(kid) (\(keyID.count))")

    // 整包向量：試驗包全鏈通過（footer／清單／11 條目逐檔複驗）
    let v0 = makeVerifier(pubHex: trialPublicKeyHex, floor: 0,
                          packageID: trialID, appVersion: "1.0")
    var staging: URL? = nil
    do {
        let r = try v0.verifyAndStage(packageAt: trialPkg,
                                      expectedKind: "toolchain")
        staging = r.stagingURL
        check("trial package verifies", true)
        check("trial manifest id/epoch/entries",
              r.manifest.packageID == trialID &&
              r.manifest.securityEpoch == 3 && r.entryCount == 11,
              "id=\(r.manifest.packageID) epoch=\(r.manifest.securityEpoch) n=\(r.entryCount)")
    } catch {
        check("trial package verifies", false, "\(error)")
    }

    // 防回滾語義（規格 §12 負測基準）
    expectErr("epoch 3 < floor 5 -> ERR_ROLLBACK",
              makeVerifier(pubHex: trialPublicKeyHex, floor: 5,
                           packageID: trialID, appVersion: "1.0"),
              trialPkg, "toolchain", .rollback)
    _ = expectOK("epoch 3 == floor 3 allowed",
                 makeVerifier(pubHex: trialPublicKeyHex, floor: 3,
                              packageID: trialID, appVersion: "1.0"),
                 trialPkg, "toolchain")
    _ = expectOK("epoch 3 > floor 2 allowed",
                 makeVerifier(pubHex: trialPublicKeyHex, floor: 2,
                              packageID: trialID, appVersion: "1.0"),
                 trialPkg, "toolchain")

    // 負測：ZIP 本體翻 1 byte → 封存簽名拒；錯鑰 → 封存簽名拒
    do {
        var bytes = try Data(contentsOf: trialPkg)
        bytes[bytes.count / 2] ^= 0x01
        let tampered = FileManager.default.temporaryDirectory
            .appendingPathComponent("paxpack-tampered.pxpk")
        try bytes.write(to: tampered)
        expectErr("tamper 1 byte -> ERR_ARCHIVE_SIGNATURE",
                  makeVerifier(pubHex: trialPublicKeyHex, floor: 0,
                               packageID: trialID, appVersion: "1.0"),
                  tampered, "toolchain", .archiveSignature)
        try? FileManager.default.removeItem(at: tampered)
    } catch {
        check("tamper setup", false, "\(error)")
    }
    expectErr("trial pkg with official key -> ERR_ARCHIVE_SIGNATURE",
              PaxPackVerifier(appVersion: "1.0",
                              floorStore: MemoryPaxPackFloorStore()),
              trialPkg, "toolchain", .archiveSignature)

    // 正式鑰樣本包：以 App 內嵌信任根（預設）驗過
    let mOff = expectOK(
        "official sample verifies with embedded key",
        PaxPackVerifier(appVersion: "0.1.0",
                        floorStore: MemoryPaxPackFloorStore()),
        officialPkg, "toolchain")
    check("official sample id/epoch",
          mOff?.packageID == "com.paxidx.official-sample" &&
          mOff?.securityEpoch == 1,
          "got \(String(describing: mOff?.packageID))")

    // §12 Mach-O 向量（標本取自試驗包已驗證的暫存區）
    guard let stage = staging else {
        check("specimens available", false, "trial staging missing")
        return
    }
    defer { try? FileManager.default.removeItem(at: stage) }
    let thinURL = stage.appendingPathComponent("lib/libopenssl.dylib")
    let fatURL = stage.appendingPathComponent("lib/libopenssl-fat.dylib")
    let helloURL = stage.appendingPathComponent("bin/hello-tool")
    let linkURL = stage.appendingPathComponent("lib/libssl-link.dylib")
    guard let thin = try? Data(contentsOf: thinURL),
          let fat = try? Data(contentsOf: fatURL),
          let hello = try? Data(contentsOf: helloURL) else {
        check("specimens readable", false)
        return
    }
    let thinHashA =
        "418891ca805e76184ad06d9c32ae1b4889aa55ee61cb28255a9741784f6d9cf4"
    let fatHashB =
        "3d2a7cf5a2faaf7034e6c5ee711ad6b9d7c6bef77eb75844a2eba1ab5eaa0b22"
    let helloHash =
        "33716d0fc013a69ba7d5b3c6c628f30cac17de270e988aaa8f0b60a9cd8a15f4"
    check("specimen A thin digest == §12", machoHex(thin) == thinHashA,
          machoHex(thin) ?? "nil")
    check("specimen B fat digest == §12", machoHex(fat) == fatHashB,
          machoHex(fat) ?? "nil")
    check("hello-tool digest == §12", machoHex(hello) == helloHash,
          machoHex(hello) ?? "nil")
    let linkTarget = try? FileManager.default
        .destinationOfSymbolicLink(atPath: linkURL.path)
    check("staged symlink target", linkTarget == "libopenssl.dylib",
          linkTarget ?? "nil")

    // 六格不變性（規格 §12；與第一期 Python 實驗同表）
    guard let layout = thinLayout(thin) else {
        check("thin layout parsed", false)
        return
    }
    let base = machoHex(thin)
    var d = thin
    for i in 0..<32 { d[layout.dataoff + 100 + i] ^= 0xFF }
    check("cell1 blob bytes flipped -> same", machoHex(d) == base)
    d = thin
    withUnsafeBytes(of: UInt32(999999).littleEndian) { raw in
        d.replaceSubrange(layout.sigCmdOff + 12..<layout.sigCmdOff + 16,
                          with: raw)
    }
    check("cell2 datasize=999999 -> same", machoHex(d) == base)
    check("cell3a blob +777B -> same",
          machoHex(thin + Data(count: 777)) == base)
    check("cell3b blob -1000B -> same",
          machoHex(thin.dropLast(1000)) == base)
    d = thin
    withUnsafeBytes(of: UInt64(0xDEAD0000).littleEndian) { raw in
        d.replaceSubrange(
            layout.linkeditVmsizeOff..<layout.linkeditVmsizeOff + 8,
            with: raw)
    }
    check("cell4 __LINKEDIT vmsize changed -> same", machoHex(d) == base)
    d = thin
    d[layout.dataoff - 16] ^= 0x01
    check("cell5 code byte flipped -> DIFFERENT", machoHex(d) != base)

    // fat 附帶格：第一片簽名區翻 byte 不變、code 翻 byte 變
    let fbase = machoHex(fat)
    let sliceOff = Int(paxU32BE(fat, 16))
    if let sl = thinLayout(fat.subdata(in: sliceOff..<fat.count)) {
        var fd = fat
        fd[sliceOff + sl.dataoff + 50] ^= 0xFF
        check("fat cell: slice blob flipped -> same",
              machoHex(fd) == fbase)
        fd = fat
        fd[sliceOff + sl.dataoff - 16] ^= 0x01
        check("fat cell: slice code flipped -> DIFFERENT",
              machoHex(fd) != fbase)
    } else {
        check("fat slice layout parsed", false)
    }

    // Keychain 下限儲存來回（CI 環境差異大，列軟性檢查；真機為準）
    let kc = KeychainPaxPackFloorStore()
    do {
        try kc.commitFloor(7, for: "com.paxidx.test.scratch")
        checkSoft("keychain floor round-trip",
                  kc.floor(for: "com.paxidx.test.scratch") == 7)
    } catch {
        checkSoft("keychain floor round-trip", false, "\(error)")
    }

    print("== \(passCount)/\(passCount + failCount) passed ==")
}

/// CLI verify 模式用：對任意 packageID 都回同一固定下限。
struct FixedFloorStore: PaxPackFloorStore {
    let value: Int
    func floor(for packageID: String) -> Int { value }
    func commitFloor(_ epoch: Int, for packageID: String) throws {}
}

// MARK: - 入口

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "selftest":
    guard args.count == 3 else {
        print("usage: selftest <fixtureDir>")
        exit(64)
    }
    runSelftest(args[2])
    exit(failCount == 0 ? 0 : 1)
case "verify":
    guard args.count == 7 else {
        print("usage: verify <pkg> <pubHex|default> <floor> <kind> " +
              "<appVersion>")
        exit(64)
    }
    let pub = args[3] == "default"
        ? PaxPackTrustRoot.officialPublicKeyRaw
        : Data(paxHexString: args[3])!
    let verifier = PaxPackVerifier(
        publicKeyRaw: pub, appVersion: args[6],
        floorStore: FixedFloorStore(value: Int(args[4]) ?? 0))
    do {
        let r = try verifier.verifyAndStage(
            packageAt: URL(fileURLWithPath: args[2]),
            expectedKind: args[5])
        print("OK \(r.manifest.packageID) epoch " +
              "\(r.manifest.securityEpoch) entries \(r.entryCount)")
        try? FileManager.default.removeItem(at: r.stagingURL)
        exit(0)
    } catch let e as PaxPackError {
        print(e.code.rawValue)
        exit(2)
    } catch {
        print("ERR_FORMAT")
        exit(2)
    }
case "macho-hash":
    guard args.count == 3 else {
        print("usage: macho-hash <file>")
        exit(64)
    }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        let digest = try PaxPackMachO.digest(data: data)
        print(digest.paxHexString)
        exit(0)
    } catch let e as PaxPackError {
        print(e.code.rawValue)
        exit(2)
    } catch {
        print("ERR_MACHO")
        exit(2)
    }
default:
    print("usage: selftest|verify|macho-hash ...")
    exit(64)
}
