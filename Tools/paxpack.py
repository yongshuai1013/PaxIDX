#!/usr/bin/env python3
"""
paxpack.py - PaxPack 簽名工具鏈包的離線打包端工具。

格式定義以 ../files/paxpack-format-spec-v1.md 為準（本工具與該規格
逐條對應）。子命令：
    genkey --name NAME [--dir DIR]      產生 P-256 簽發鑰對
    pack   --src DIR --key PRIV.pem --out PKG.pxpk \
           --id ID --name NAME --version VER --epoch N \
           --min-app VER --kind KIND [--desc TEXT]
    verify PKG --public PUB.pem [--installed-epoch N]
    info   PKG [--public PUB.pem]

只依賴 Python 3 標準庫與 openssl 命令行。Mach-O 補簽需要 codesign
（或相容 shim）或 ldid 在 PATH 上（見規格 §9）。
"""

import argparse
import hashlib
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

MAGIC = b'PXPK0001'
FOOTER = struct.Struct('<8sQB64s')          # magic, archive_len, rev, raw sig
FOOTER_REV = 1

ARCHIVE_DOMAIN = b'PaxPack/archive#1\0'
LIST_DOMAIN = b'PaxPack/filelist#1\0'
MACHO_DOMAIN = b'PaxPack/macho#1\0'
FAT_DOMAIN = b'PaxPack/fat#1\0'
FILE_DOMAIN = b'PaxPack/file#1\0'
DIR_DOMAIN = b'PaxPack/dir#1\0'
LINK_DOMAIN = b'PaxPack/link#1\0'

MANIFEST_NAME = 'manifest.plist'
LIST_NAME = 'PXFileList.plist'
SPKI_PREFIX = bytes.fromhex(
    '3059301306072a8648ce3d020106082a8648ce3d030107034200')

LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0x0D
LC_CODE_SIGNATURE = 0x1D
ZEROFILL_TYPES = (0x1, 0xC, 0x12)            # S_ZEROFILL / GB / THREAD_LOCAL


class PackError(Exception):
    pass


def fail(msg):
    raise PackError(msg)


def openssl(args, data=None):
    r = subprocess.run(['openssl', *args], input=data, capture_output=True)
    if r.returncode:
        fail(f"openssl {args[0]}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


# MARK: 金鑰與簽名（ECDSA P-256；簽名以 raw r||s 64 byte 儲存）

def raw_public_key(pem_path):
    """回傳公鑰未壓縮點 65 byte。pem_path 可為私鑰或公鑰 PEM。"""
    data = Path(pem_path).read_bytes()
    args = ['pkey', '-in', str(pem_path), '-pubout', '-outform', 'DER']
    if b'PRIVATE KEY' not in data:
        args.insert(1, '-pubin')
    der = openssl(args)
    if not der.startswith(SPKI_PREFIX) or len(der) != len(SPKI_PREFIX) + 65:
        fail(f'{pem_path} is not a P-256 key')
    return der[len(SPKI_PREFIX):]


def key_id(pem_path):
    return hashlib.sha256(raw_public_key(pem_path)).hexdigest()[:16]


def _der_len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b


def _read_len(d, i):
    n = d[i]
    i += 1
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(d[i:i + k], 'big')
        i += k
    return n, i


def _int_enc(x32):
    b = x32.lstrip(b'\0') or b'\0'
    if b[0] & 0x80:
        b = b'\0' + b
    return b'\x02' + _der_len(len(b)) + b


def raw_to_der(raw):
    if len(raw) != 64:
        fail('raw signature must be 64 bytes')
    body = _int_enc(raw[:32]) + _int_enc(raw[32:])
    return b'\x30' + _der_len(len(body)) + body


def der_to_raw(der):
    if not der or der[0] != 0x30:
        fail('bad DER signature')
    _, i = _read_len(der, 1)
    out = []
    for _ in range(2):
        if der[i] != 0x02:
            fail('bad DER signature')
        n, i = _read_len(der, i + 1)
        v = der[i:i + n]
        i += n
        if len(v) > 33 or (len(v) == 33 and v[0] != 0):
            fail('bad DER integer in signature')
        out.append(v[-32:].rjust(32, b'\0'))
    return out[0] + out[1]


def ecdsa_sign(priv_pem, preimage):
    """對 preimage 做 ECDSA(SHA-256) 簽名，回傳 raw 64 byte。"""
    der = openssl(['dgst', '-sha256', '-sign', str(priv_pem)], data=preimage)
    return der_to_raw(der)


def ecdsa_verify(pub_pem, preimage, raw_sig):
    """驗 raw 簽名；成功回 True，失敗回 False（openssl 報錯視為失敗）。"""
    with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as f:
        f.write(raw_to_der(raw_sig))
        sigfile = f.name
    try:
        r = subprocess.run(['openssl', 'dgst', '-sha256', '-verify',
                            str(pub_pem), '-signature', sigfile],
                           input=preimage, capture_output=True)
        return r.returncode == 0
    finally:
        os.unlink(sigfile)


# MARK: 雜湊串流（域字串開頭；其餘元件逐一 length-frame）

def frame(h, b):
    h.update(struct.pack('<Q', len(b)))
    h.update(b)


def digest_of(domain, chunks):
    h = hashlib.sha256()
    h.update(domain)
    for c in chunks:
        frame(h, c)
    return h.digest()


def file_digest(data):
    return digest_of(FILE_DOMAIN, [data])


def dir_digest(relpath):
    return digest_of(DIR_DOMAIN, [relpath.encode('utf-8')])


def link_digest(target):
    return digest_of(LINK_DOMAIN, [target.encode('utf-8')])


# MARK: Mach-O 解析與正規化雜湊（規格 §6）

def macho_kind(data):
    """'thin64' / 'fat' / 'unsupported' / None（非 Mach-O）。"""
    if len(data) < 4:
        return None
    magic = struct.unpack_from('<I', data)[0]
    if magic == 0xFEEDFACF:
        return 'thin64'
    if magic in (0xBEBAFECA, 0xBFBAFECA):      # fat（大小端標頭）
        return 'fat'
    if magic in (0xFEEDFACE, 0xCEFAEDFE, 0xCFFAEDFE,
                 0xCAFEBABE, 0xCAFEBABF):      # 32-bit / Java class 等
        return 'unsupported'
    return None


def _thin_commands(data):
    """驗證 thin 標頭並回傳 [(cmd, offset, size)]。"""
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        fail('not a 64-bit Mach-O')
    ncmds, sizeofcmds = struct.unpack_from('<II', data, 16)
    if ncmds == 0 or sizeofcmds > len(data) - 32 or sizeofcmds > 1 << 24:
        fail('malformed load commands')
    cmds, off, end = [], 32, 32 + sizeofcmds
    for _ in range(ncmds):
        if end - off < 8:
            fail('malformed load commands')
        cmd, size = struct.unpack_from('<II', data, off)
        if size < 8 or size % 8 or size > end - off:
            fail('malformed load commands')
        if cmd == LC_SEGMENT_64 and (
                size < 72 or
                struct.unpack_from('<I', data, off + 64)[0] > (size - 72) // 80):
            fail('malformed segment')
        cmds.append((cmd, off, size))
        off += size
    if off != end:
        fail('malformed load commands')
    return cmds


def _sig_dataoff(data, cmds):
    sigs = [(o, s) for c, o, s in cmds if c == LC_CODE_SIGNATURE]
    if len(sigs) != 1:
        fail('Mach-O must have exactly one LC_CODE_SIGNATURE '
             '(ad hoc sign it first)' if not sigs else
             'more than one code signature')
    o, s = sigs[0]
    if s != 16:
        fail('malformed LC_CODE_SIGNATURE')
    dataoff = struct.unpack_from('<I', data, o + 8)[0]
    cmds_end = 32 + struct.unpack_from('<I', data, 20)[0]
    if dataoff < cmds_end or dataoff > len(data):
        fail('code signature lies outside the file')
    return dataoff


def _code_start(data, cmds, dataoff):
    start = dataoff
    for cmd, off, size in cmds:
        if cmd != LC_SEGMENT_64:
            continue
        fileoff, filesize = struct.unpack_from('<QQ', data, off + 40)
        if fileoff > 0 and filesize > 0:
            start = min(start, fileoff)
        nsects = struct.unpack_from('<I', data, off + 64)[0]
        for j in range(nsects):
            so = off + 72 + 80 * j
            stype = struct.unpack_from('<I', data, so + 64)[0] & 0xFF
            ssize, soffset = struct.unpack_from('<QI', data, so + 40)
            if stype not in ZEROFILL_TYPES and ssize > 0 and soffset > 0:
                start = min(start, soffset)
    return start


def _normalized_command(data, cmd, off, size):
    raw = bytearray(data[off:off + size])
    if cmd == LC_CODE_SIGNATURE:
        struct.pack_into('<I', raw, 12, 0)          # datasize 歸零
    elif cmd == LC_SEGMENT_64:
        name = bytes(raw[8:24]).split(b'\0')[0]
        if name == b'__LINKEDIT':
            struct.pack_into('<Q', raw, 32, 0)      # vmsize
            struct.pack_into('<Q', raw, 48, 0)      # filesize
        elif name == b'__PAGEZERO':
            struct.pack_into('<Q', raw, 24, 0)      # vmaddr
            struct.pack_into('<Q', raw, 32, 0)      # vmsize
    return bytes(raw)


def thin_digest(data):
    """單一切片的正規化雜湊（規格 §6.2／§6.3）。回傳 32 byte。"""
    cmds = _thin_commands(data)
    dataoff = _sig_dataoff(data, cmds)
    start = _code_start(data, cmds, dataoff)
    cmds_end = 32 + struct.unpack_from('<I', data, 20)[0]
    if any(data[cmds_end:start]):
        fail('non-zero padding between load commands and code')
    h = hashlib.sha256()
    h.update(MACHO_DOMAIN)
    frame(h, data[:32])                             # header 逐字
    frame(h, struct.pack('<Q', start))
    frame(h, struct.pack('<Q', dataoff))
    for cmd, off, size in cmds:
        frame(h, _normalized_command(data, cmd, off, size))
    frame(h, data[start:dataoff])
    return h.digest()


def fat_digest(data):
    """fat 彙總雜湊（規格 §6.4）。"""
    if len(data) < 8:
        fail('truncated fat header')
    narch = struct.unpack_from('>I', data, 4)[0]
    if narch == 0 or narch > 16:
        fail('implausible fat arch count')
    h = hashlib.sha256()
    h.update(FAT_DOMAIN)
    off = 8
    for _ in range(narch):
        if off + 20 > len(data):
            fail('truncated fat arch entry')
        cputype, cpusub, soff, ssize = struct.unpack_from('>IIII', data, off)
        off += 20
        if soff + ssize > len(data) or ssize < 32:
            fail('fat slice out of bounds')
        frame(h, struct.pack('<I', cputype))
        frame(h, struct.pack('<I', cpusub))
        frame(h, thin_digest(data[soff:soff + ssize]))
    return h.digest()


def macho_digest(data):
    kind = macho_kind(data)
    if kind == 'thin64':
        return thin_digest(data)
    if kind == 'fat':
        return fat_digest(data)
    fail('unsupported Mach-O (32-bit or big-endian)')


def _fat_slices(data):
    """fat 切片位元組列表；標頭不合理（arch 數或範圍越界）回 None。"""
    if len(data) < 8:
        return None
    narch = struct.unpack_from('>I', data, 4)[0]
    if narch == 0 or narch > 16:
        return None
    out = []
    off = 8
    for _ in range(narch):
        if off + 20 > len(data):
            return None
        _, _, soff, ssize = struct.unpack_from('>IIII', data, off)
        off += 20
        if soff + ssize > len(data):
            return None
        out.append(data[soff:soff + ssize])
    return out


def macho_state(data):
    """條目分類（打包端與驗證端共用、必須逐字一致，規格 §6.1 分類
    規則）：回 'macho'（已合 §6.1 簽名資格，按 §6 計雜湊）、
    'candidate'（Mach-O 形但缺簽名，待打包端補簽或降級）、'file'
    （按一般檔逐字節計，含 fat 包非 Mach-O 切片、以及合不了簽名
    資格的內容）、'unsupported'（32-bit／大端 Mach-O）。"""
    kind = macho_kind(data)
    if kind is None:
        return 'file'
    if kind == 'unsupported':
        return 'unsupported'
    if kind == 'fat':
        slices = _fat_slices(data)
        if slices is None:
            return 'file'
        if any(macho_kind(sl) != 'thin64' for sl in slices):
            return 'file'
    return 'macho' if has_code_signature(data) else 'candidate'


def has_code_signature(data):
    kind = macho_kind(data)
    try:
        if kind == 'thin64':
            _sig_dataoff(data, _thin_commands(data))
            return True
        if kind == 'fat':
            narch = struct.unpack_from('>I', data, 4)[0]
            off = 8
            for _ in range(narch):
                _, _, soff, ssize = struct.unpack_from('>IIII', data, off)
                off += 20
                _sig_dataoff(data[soff:soff + ssize],
                             _thin_commands(data[soff:soff + ssize]))
            return True
    except PackError:
        return False
    return False


# MARK: ad hoc 補簽（規格 §9；codesign／shim 優先、ldid 次之）

def signer_available():
    return bool(os.environ.get('PAXPACK_SIGNER')
                or shutil.which('codesign') or shutil.which('ldid'))


def adhoc_sign(path):
    custom = os.environ.get('PAXPACK_SIGNER')
    if custom:
        r = subprocess.run([custom, str(path)], capture_output=True)
    elif shutil.which('codesign'):
        r = subprocess.run(['codesign', '--sign', '-', '--force', str(path)],
                           capture_output=True)
    elif shutil.which('ldid'):
        r = subprocess.run(['ldid', '-S', str(path)], capture_output=True)
    else:
        fail(f'{path}: unsigned Mach-O and no codesign/ldid available')
    if r.returncode:
        fail(f'ad hoc sign failed for {path}: '
             f'{r.stderr.decode(errors="replace").strip()}')


# MARK: 來源樹盤點（回傳 [(relpath, kind, abspath)]，路徑以 / 分隔）

def scan_tree(root):
    root = Path(root)
    out = []

    def walk(d, prefix):
        for name in sorted(os.listdir(d)):
            p = d / name
            rel = f'{prefix}{name}'
            if p.is_symlink():
                out.append((rel, 'link', p))
            elif p.is_dir():
                out.append((rel, 'dir', p))
                walk(p, rel + '/')
            elif p.is_file():
                data = p.read_bytes()
                state = macho_state(data)
                if state in ('macho', 'candidate'):
                    out.append((rel, 'macho', p))
                elif state == 'unsupported':
                    fail(f'{rel}: unsupported Mach-O (32-bit or big-endian)')
                else:
                    out.append((rel, 'file', p))
            else:
                fail(f'{rel}: special file not allowed in package')

    walk(root, '')
    return out


def entry_digest(kind, rel, abspath):
    if kind == 'dir':
        return dir_digest(rel), 0
    if kind == 'link':
        target = os.readlink(abspath)
        return link_digest(target), len(target.encode('utf-8'))
    data = Path(abspath).read_bytes()
    if kind == 'macho':
        return macho_digest(data), len(data)
    return file_digest(data), len(data)


# MARK: ZIP 確定性寫入（規格 §3 第 4 條）

def write_zip(top, items, out_path):
    """items: [(relpath, kind, abspath)]；寫入 top/ 前綴的 ZIP 本體。"""
    names = sorted(items, key=lambda it: it[0].encode('utf-8'))
    with zipfile.ZipFile(out_path, 'w', zipfile.ZIP_DEFLATED) as z:
        def add(arcname, kind, abspath=None):
            info = zipfile.ZipInfo(arcname, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            if kind == 'dir':
                info.external_attr = (0o40755 << 16) | 0x10
                z.writestr(info, b'')
            elif kind == 'link':
                info.external_attr = 0o120777 << 16
                z.writestr(info, os.readlink(abspath).encode('utf-8'))
            else:
                info.external_attr = 0o100644 << 16
                z.writestr(info, Path(abspath).read_bytes())

        add(top + '/', 'dir')
        for rel, kind, abspath in names:
            add(f'{top}/{rel}' + ('/' if kind == 'dir' else ''), kind, abspath)


def identifier_valid(value):
    return (isinstance(value, str) and 0 < len(value) <= 255
            and re.fullmatch(r'[A-Za-z0-9._-]+', value) is not None
            and len(value.split('.')) >= 2 and all(value.split('.')))


# MARK: 子命令 genkey

def cmd_genkey(args):
    out_dir = Path(args.dir) if args.dir else Path.home() / '.config/paxpack/keys'
    out_dir.mkdir(parents=True, exist_ok=True)
    priv = out_dir / f'{args.name}.key.pem'
    pub = out_dir / f'{args.name}.pub.pem'
    if priv.exists() or pub.exists():
        fail(f'key {args.name} already exists in {out_dir}')
    openssl(['ecparam', '-name', 'prime256v1', '-genkey', '-noout',
             '-out', str(priv)])
    os.chmod(priv, 0o600)
    openssl(['pkey', '-in', str(priv), '-pubout', '-out', str(pub)])
    print(f'private: {priv}')
    print(f'public:  {pub}')
    print(f'key id:  {key_id(pub)}')


# MARK: 子命令 pack（規格 §9）

def cmd_pack(args):
    if not identifier_valid(args.id):
        fail('--id must be reverse DNS (letters, digits, ".", "-", "_")')
    if args.epoch < 1:
        fail('--epoch must be >= 1')
    src = Path(args.src)
    if not src.is_dir():
        fail(f'{src} is not a directory')
    top = args.top or src.name

    with tempfile.TemporaryDirectory(prefix='paxpack-') as td:
        stage = Path(td) / top
        shutil.copytree(src, stage, symlinks=True)

        # 補簽未簽名 Mach-O（暫存副本上），再逐個 §6.1 自檢。
        # 簽名工具拒簽的型別（如 MH_DYLIB_STUB）降為一般檔逐字節計
        # （規格 §6.1 分類規則）：此類內容在本格式的安裝流程中不會
        # 被重簽，逐字節雜湊的完整性更強，不視為打包失敗。
        demoted = set()
        for rel, kind, p in scan_tree(stage):
            if kind != 'macho':
                continue
            if macho_state(p.read_bytes()) == 'macho':
                macho_digest(p.read_bytes())
                continue
            if not signer_available():
                fail(f'{rel}: unsigned Mach-O and no codesign/ldid '
                     f'available')
            try:
                adhoc_sign(p)
            except PackError:
                demoted.add(rel)
                print(f'note: {rel}: not signable, packed as plain file')
                continue
            if macho_state(p.read_bytes()) != 'macho':
                # 簽名工具回成功但產物仍不合 §6.1（如 codesign 對
                # stub 只做半套）：同拒簽處理，降為一般檔。分類由
                # 位元組決定、驗證端同法判定，兩邊必然一致。
                demoted.add(rel)
                print(f'note: {rel}: still unqualified after ad hoc '
                      f'sign, packed as plain file')
                continue
            macho_digest(p.read_bytes())

        manifest = {
            'PXFormatVersion': 1,
            'PXPackageID': args.id,
            'PXName': args.name,
            'PXVersion': args.version,
            'PXSecurityEpoch': args.epoch,
            'PXMinAppVersion': args.min_app,
            'PXPayloadKind': args.kind,
            'PXPayloadDescription': args.desc or '',
        }
        with open(stage / MANIFEST_NAME, 'wb') as f:
            plistlib.dump(manifest, f, fmt=plistlib.FMT_XML, sort_keys=True)

        entries = []
        for rel, kind, p in scan_tree(stage):
            if rel in demoted:
                kind = 'file'
            d, size = entry_digest(kind, rel, p)
            entries.append({'path': rel, 'kind': kind, 'size': size,
                            'sha256': d.hex()})
        entries.sort(key=lambda e: e['path'].encode('utf-8'))

        filelist = {'PXListFormat': 1, 'PXPackageID': args.id,
                    'PXSecurityEpoch': args.epoch, 'entries': entries}
        canonical = plistlib.dumps(filelist, fmt=plistlib.FMT_XML,
                                   sort_keys=True)
        filelist['pxListSignature'] = ecdsa_sign(
            args.key, LIST_DOMAIN + canonical)
        with open(stage / LIST_NAME, 'wb') as f:
            plistlib.dump(filelist, f, fmt=plistlib.FMT_XML, sort_keys=True)

        zip_path = Path(td) / 'body.zip'
        write_zip(top, scan_tree(stage), zip_path)
        zip_bytes = zip_path.read_bytes()

    sig = ecdsa_sign(args.key, ARCHIVE_DOMAIN + zip_bytes)
    out = Path(args.out)
    with open(out, 'wb') as f:
        f.write(zip_bytes)
        f.write(FOOTER.pack(MAGIC, len(zip_bytes), FOOTER_REV, sig))

    # §9 第 5 條：產出後立即自驗
    with tempfile.NamedTemporaryFile(suffix='.pem', delete=False) as f:
        pub_tmp = f.name
    try:
        openssl(['pkey', '-in', str(args.key), '-pubout', '-out', pub_tmp])
        verify_package(out, pub_tmp, None)
    finally:
        os.unlink(pub_tmp)
    print(f'packed: {out} ({out.stat().st_size} bytes, '
          f'{len(entries)} entries, epoch {args.epoch}, '
          f'key {key_id(args.key)})')


# MARK: 驗證（規格 §8 的離線對應；App 端契約的步驟與錯誤分類逐一對齊）

def _manifest_check(m):
    def bad(msg):
        fail(f'ERR_MANIFEST: {msg}')
    if not isinstance(m, dict):
        bad('manifest is not a dict')
    if type(m.get('PXFormatVersion')) is not int or m['PXFormatVersion'] != 1:
        bad('PXFormatVersion must be int 1')
    if not identifier_valid(m.get('PXPackageID')):
        bad('PXPackageID invalid')
    for k in ('PXName', 'PXVersion', 'PXMinAppVersion', 'PXPayloadKind'):
        if not isinstance(m.get(k), str) or not m[k]:
            bad(f'{k} must be a non-empty string')
    if type(m.get('PXSecurityEpoch')) is not int or m['PXSecurityEpoch'] < 1:
        bad('PXSecurityEpoch must be int >= 1')


def _zip_entries(zf, top):
    """由 ZIP 重算逐條目雜湊，回傳 {path: (kind, size, hex)}。"""
    out = {}
    prefix = top + '/'
    for info in zf.infolist():
        name = info.filename
        if name == prefix:
            continue
        if not name.startswith(prefix):
            fail(f'ERR_PATH: entry outside top dir: {name}')
        rel = name[len(prefix):]
        mode = (info.external_attr >> 16) & 0o170000
        if name.endswith('/'):
            rel = rel.rstrip('/')
            if not rel:
                continue
            kind, d, size = 'dir', dir_digest(rel), 0
        elif mode == 0o120000:
            target = zf.read(name).decode('utf-8')
            joined = os.path.normpath(
                os.path.join(os.path.dirname(rel), target))
            if os.path.isabs(target) or joined.startswith('..'):
                fail(f'ERR_PATH: symlink escapes package: {rel}')
            kind, d, size = 'link', link_digest(target), \
                len(target.encode('utf-8'))
        else:
            data = zf.read(name)
            state = macho_state(data)
            if state == 'macho':
                try:
                    d = macho_digest(data)
                except PackError as e:
                    fail(f'ERR_MACHO: {rel}: {e}')
                kind = 'macho'
            elif state == 'unsupported':
                fail(f'ERR_MACHO: {rel}: unsupported Mach-O')
            else:
                d = file_digest(data)
                kind = 'file'
            size = len(data)
        if rel in out:
            fail(f'ERR_PATH: duplicate entry {rel}')
        out[rel] = (kind, size, d.hex())
    return out


def verify_package(pkg_path, pub_pem, installed_epoch):
    import io
    data = Path(pkg_path).read_bytes()
    if len(data) < FOOTER.size:
        fail('ERR_FORMAT: file shorter than footer')
    magic, alen, rev, sig = FOOTER.unpack(data[-FOOTER.size:])
    if magic != MAGIC or rev != FOOTER_REV or alen != len(data) - FOOTER.size:
        fail('ERR_FORMAT: bad footer')
    zip_bytes = data[:alen]
    if not ecdsa_verify(pub_pem, ARCHIVE_DOMAIN + zip_bytes, sig):
        fail('ERR_ARCHIVE_SIGNATURE: archive signature does not verify')
    try:
        zf = zipfile.ZipFile(io.BytesIO(zip_bytes))
    except zipfile.BadZipFile:
        fail('ERR_FORMAT: not a ZIP archive')
    names = [n for n in zf.namelist() if n and not n.startswith('__MACOSX/')]
    if len(names) != len(set(names)):
        fail('ERR_PATH: duplicate entries in ZIP')
    tops = {n.split('/', 1)[0] for n in names}
    if len(tops) != 1:
        fail('ERR_FORMAT: package must hold exactly one top-level directory')
    top = tops.pop()
    try:
        manifest = plistlib.loads(zf.read(f'{top}/{MANIFEST_NAME}'))
    except KeyError:
        fail('ERR_MANIFEST: manifest.plist missing')
    _manifest_check(manifest)
    if installed_epoch is not None and \
            manifest['PXSecurityEpoch'] < installed_epoch:
        fail(f"ERR_ROLLBACK: package epoch {manifest['PXSecurityEpoch']} "
             f'< installed floor {installed_epoch}')
    try:
        filelist = plistlib.loads(zf.read(f'{top}/{LIST_NAME}'))
    except KeyError:
        fail('ERR_LIST_SIGNATURE: PXFileList.plist missing')
    lsig = filelist.pop('pxListSignature', None)
    if not isinstance(lsig, bytes) or len(lsig) != 64:
        fail('ERR_LIST_SIGNATURE: missing/invalid list signature')
    canonical = plistlib.dumps(filelist, fmt=plistlib.FMT_XML, sort_keys=True)
    if not ecdsa_verify(pub_pem, LIST_DOMAIN + canonical, lsig):
        fail('ERR_LIST_SIGNATURE: list signature does not verify')
    if filelist.get('PXPackageID') != manifest['PXPackageID'] or \
            filelist.get('PXSecurityEpoch') != manifest['PXSecurityEpoch']:
        fail('ERR_LIST_SIGNATURE: list/manifest id or epoch mismatch')
    listed = {}
    for e in filelist.get('entries', []):
        listed[e['path']] = (e['kind'], e['size'], e['sha256'])
    actual = _zip_entries(zf, top)
    actual.pop(LIST_NAME, None)
    if set(actual) != set(listed):
        fail(f'ERR_ENTRY_MISMATCH: entry set differs '
             f'(only-in-zip={sorted(set(actual) - set(listed))}, '
             f'only-in-list={sorted(set(listed) - set(actual))})')
    for path, want in listed.items():
        if actual[path] != want:
            fail(f'ERR_ENTRY_MISMATCH: {path}')
    return manifest, filelist, len(listed)


def cmd_verify(args):
    manifest, _, n = verify_package(args.pkg, args.public,
                                    args.installed_epoch)
    print(f"OK: {manifest['PXPackageID']} epoch "
          f"{manifest['PXSecurityEpoch']}, {n} entries, "
          f"signed by key {key_id(args.public)}")


def cmd_info(args):
    import io
    data = Path(args.pkg).read_bytes()
    if len(data) < FOOTER.size:
        fail('file shorter than footer')
    magic, alen, rev, sig = FOOTER.unpack(data[-FOOTER.size:])
    print(f'footer: magic={magic.decode()} rev={rev} '
          f'archive={alen} bytes total={len(data)} bytes')
    zf = zipfile.ZipFile(io.BytesIO(data[:alen]))
    top = {n.split('/', 1)[0] for n in zf.namelist() if n}.pop()
    manifest = plistlib.loads(zf.read(f'{top}/{MANIFEST_NAME}'))
    for k in sorted(manifest):
        print(f'  {k}: {manifest[k]}')
    filelist = plistlib.loads(zf.read(f'{top}/{LIST_NAME}'))
    print(f"  entries: {len(filelist.get('entries', []))}")
    if args.public:
        ok = ecdsa_verify(args.public, ARCHIVE_DOMAIN + data[:alen], sig)
        print(f'  archive signature: '
              f'{"valid" if ok else "INVALID"} for key {key_id(args.public)}')


def main(argv=None):
    ap = argparse.ArgumentParser(prog='paxpack', description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)

    g = sub.add_parser('genkey')
    g.add_argument('--name', required=True)
    g.add_argument('--dir')
    g.set_defaults(fn=cmd_genkey)

    p = sub.add_parser('pack')
    p.add_argument('--src', required=True)
    p.add_argument('--key', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--id', required=True)
    p.add_argument('--name', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--epoch', required=True, type=int)
    p.add_argument('--min-app', required=True)
    p.add_argument('--kind', required=True)
    p.add_argument('--desc')
    p.add_argument('--top')
    p.set_defaults(fn=cmd_pack)

    v = sub.add_parser('verify')
    v.add_argument('pkg')
    v.add_argument('--public', required=True)
    v.add_argument('--installed-epoch', type=int)
    v.set_defaults(fn=cmd_verify)

    i = sub.add_parser('info')
    i.add_argument('pkg')
    i.add_argument('--public')
    i.set_defaults(fn=cmd_info)

    args = ap.parse_args(argv)
    try:
        args.fn(args)
    except PackError as e:
        print(f'paxpack: {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
