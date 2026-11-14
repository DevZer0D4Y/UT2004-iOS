#!/usr/bin/env python3
"""Small Mach-O (arm64, thin, unsigned) surgery tool for the UT2004 iOS port.

Commands
  exe2dylib <in> <out> <install_name>
      Turn a PIE MH_EXECUTE into an MH_DYLIB: drop __PAGEZERO, LC_MAIN and
      LC_LOAD_DYLINKER, add LC_ID_DYLIB, and renumber segment indices in the
      rebase/bind/weak/lazy opcode streams (__PAGEZERO was segment 0).
  patchstr <in> <out> <old>=<new> [...]
      Replace NUL-terminated C strings in place. <new> must not be longer
      than <old>; the rest is NUL padded. Each <old> must occur exactly once.
  rebind <in> <out> <dependency install name> <symbol> [...]
      Point the lazy binds of <symbol>s at another existing dependency
      (used to move macOS-only imports onto a shim library).
  info <in>
      Print load commands.
The input must already be thin (lipo -thin arm64) and unsigned
(codesign --remove-signature); re-sign after editing.
"""
import struct
import sys

MH_MAGIC_64 = 0xfeedfacf
MH_EXECUTE, MH_DYLIB = 2, 6
MH_PIE = 0x200000
LC_REQ_DYLD = 0x80000000
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xd
LC_LOAD_DYLINKER = 0xe
LC_MAIN = 0x28 | LC_REQ_DYLD
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
LC_CODE_SIGNATURE = 0x1d
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

NAMES = {0x19: 'LC_SEGMENT_64', 0x2: 'LC_SYMTAB', 0xb: 'LC_DYSYMTAB', 0xc: 'LC_LOAD_DYLIB',
         0xd: 'LC_ID_DYLIB', 0xe: 'LC_LOAD_DYLINKER', 0x1b: 'LC_UUID', 0x32: 'LC_BUILD_VERSION',
         0x2a: 'LC_SOURCE_VERSION', LC_MAIN: 'LC_MAIN', LC_DYLD_INFO_ONLY: 'LC_DYLD_INFO_ONLY',
         0x26: 'LC_FUNCTION_STARTS', 0x29: 'LC_DATA_IN_CODE', 0x1d: 'LC_CODE_SIGNATURE',
         0x1c | LC_REQ_DYLD: 'LC_RPATH', 0x18 | LC_REQ_DYLD: 'LC_LOAD_WEAK_DYLIB',
         LC_DYLD_CHAINED_FIXUPS: 'LC_DYLD_CHAINED_FIXUPS', 0x33 | LC_REQ_DYLD: 'LC_DYLD_EXPORTS_TRIE'}


class MachO:
    def __init__(self, path):
        self.buf = bytearray(open(path, 'rb').read())
        magic, cpu, sub, ftype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<8I', self.buf, 0)
        if magic != MH_MAGIC_64:
            raise SystemExit('%s: not a thin 64-bit Mach-O (lipo -thin arm64 first)' % path)
        self.filetype, self.ncmds, self.sizeofcmds, self.flags = ftype, ncmds, sizeofcmds, flags
        self.cmds = []  # (cmd, offset, size)
        off = 32
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<2I', self.buf, off)
            self.cmds.append((cmd, off, size))
            off += size

    def segments(self):
        out = []
        for cmd, off, size in self.cmds:
            if cmd == LC_SEGMENT_64:
                name = self.buf[off + 8:off + 24].rstrip(b'\0').decode()
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<4Q', self.buf, off + 24)
                nsects = struct.unpack_from('<I', self.buf, off + 64)[0]
                sects = []
                for i in range(nsects):
                    s = off + 72 + i * 80
                    sname = self.buf[s:s + 16].rstrip(b'\0').decode()
                    addr, ssize = struct.unpack_from('<2Q', self.buf, s + 32)
                    soff = struct.unpack_from('<I', self.buf, s + 48)[0]
                    sects.append((sname, addr, ssize, soff))
                out.append(dict(name=name, vmaddr=vmaddr, vmsize=vmsize, fileoff=fileoff,
                                filesize=filesize, sects=sects, cmdoff=off))
        return out

    def first_section_offset(self):
        offs = [s[3] for seg in self.segments() for s in seg['sects'] if s[3]]
        return min(offs)

    def find(self, cmd):
        return [c for c in self.cmds if c[0] == cmd]


def uleb(buf, p):
    r = s = 0
    while True:
        b = buf[p]; p += 1
        r |= (b & 0x7f) << s; s += 7
        if not b & 0x80:
            return r, p


def renumber_rebase(buf, start, size, delta):
    p, end, n = start, start + size, 0
    while p < end:
        b = buf[p]; op, imm = b & 0xf0, b & 0x0f
        if op == 0x20:
            if imm + delta < 0:
                raise SystemExit('rebase references segment %d' % imm)
            buf[p] = op | (imm + delta); n += 1
            p += 1; _, p = uleb(buf, p)
        elif op in (0x30, 0x60, 0x70):
            p += 1; _, p = uleb(buf, p)
        elif op == 0x80:
            p += 1; _, p = uleb(buf, p); _, p = uleb(buf, p)
        elif op in (0x00, 0x10, 0x40, 0x50):
            p += 1
        else:
            raise SystemExit('unknown rebase opcode %#x at %#x' % (b, p))
    return n


def renumber_bind(buf, start, size, delta):
    p, end, n = start, start + size, 0
    while p < end:
        b = buf[p]; op, imm = b & 0xf0, b & 0x0f
        if op == 0x70:
            if imm + delta < 0:
                raise SystemExit('bind references segment %d' % imm)
            buf[p] = op | (imm + delta); n += 1
            p += 1; _, p = uleb(buf, p)
        elif op in (0x20, 0x60, 0x80, 0xa0):  # one uleb/sleb operand
            p += 1; _, p = uleb(buf, p)
        elif op == 0xc0:
            p += 1; _, p = uleb(buf, p); _, p = uleb(buf, p)
        elif op == 0x40:
            p = buf.index(0, p + 1) + 1
        elif op in (0x00, 0x10, 0x30, 0x50, 0x90, 0xb0):
            p += 1
        else:
            raise SystemExit('unknown bind opcode %#x at %#x' % (b, p))
    return n


def exe2dylib(src, dst, install_name):
    m = MachO(src)
    if m.filetype != MH_EXECUTE:
        raise SystemExit('not an executable')
    if m.find(LC_CODE_SIGNATURE):
        raise SystemExit('remove the code signature first (codesign --remove-signature)')
    if m.find(LC_DYLD_CHAINED_FIXUPS):
        raise SystemExit('chained fixups are not handled; this tool expects LC_DYLD_INFO_ONLY')
    segs = m.segments()
    if segs[0]['name'] != '__PAGEZERO' or segs[0]['filesize'] != 0:
        raise SystemExit('expected __PAGEZERO as the first segment')

    # 1. renumber segment indices in dyld info opcode streams
    info = m.find(LC_DYLD_INFO_ONLY) or m.find(LC_DYLD_INFO)
    if not info:
        raise SystemExit('no LC_DYLD_INFO(_ONLY)')
    _, off, _ = info[0]
    (rb_off, rb_size, b_off, b_size, wb_off, wb_size, lb_off, lb_size,
     _e_off, _e_size) = struct.unpack_from('<10I', m.buf, off + 8)
    counts = (renumber_rebase(m.buf, rb_off, rb_size, -1),
              renumber_bind(m.buf, b_off, b_size, -1),
              renumber_bind(m.buf, wb_off, wb_size, -1),
              renumber_bind(m.buf, lb_off, lb_size, -1))

    # 2. rebuild load commands
    name = install_name.encode() + b'\0'
    id_size = (24 + len(name) + 7) & ~7
    id_cmd = struct.pack('<6I', LC_ID_DYLIB, id_size, 24, 1, 0x10000, 0x10000) + name
    id_cmd += b'\0' * (id_size - len(id_cmd))
    new_cmds = []
    for cmd, off, size in m.cmds:
        raw = bytes(m.buf[off:off + size])
        if cmd == LC_SEGMENT_64 and raw[8:24].rstrip(b'\0') == b'__PAGEZERO':
            continue
        if cmd == LC_LOAD_DYLINKER:
            continue
        if cmd == LC_MAIN:
            new_cmds.append(id_cmd)
            continue
        new_cmds.append(raw)
    blob = b''.join(new_cmds)
    limit = m.first_section_offset()
    if 32 + len(blob) > limit:
        raise SystemExit('no header room for new load commands')
    m.buf[32:32 + m.sizeofcmds] = b'\0' * m.sizeofcmds
    m.buf[32:32 + len(blob)] = blob
    flags = m.flags & ~MH_PIE
    struct.pack_into('<I', m.buf, 12, MH_DYLIB)
    struct.pack_into('<2I', m.buf, 16, len(new_cmds), len(blob))
    struct.pack_into('<I', m.buf, 24, flags)
    open(dst, 'wb').write(m.buf)
    print('exe2dylib: %s -> %s (%s); segment refs renumbered rebase=%d bind=%d weak=%d lazy=%d'
          % (src, dst, install_name, *counts))


def patchstr(src, dst, pairs):
    buf = bytearray(open(src, 'rb').read())
    for pair in pairs:
        old, new = pair.split('=', 1)
        o, n = old.encode() + b'\0', new.encode() + b'\0'
        if len(n) > len(o):
            raise SystemExit('replacement longer than original: %r' % pair)
        hits = []
        i = buf.find(o)
        while i >= 0:
            if i == 0 or buf[i - 1] == 0:
                hits.append(i)
            i = buf.find(o, i + 1)
        if len(hits) != 1:
            raise SystemExit('%r found %d times (need exactly 1)' % (old, len(hits)))
        buf[hits[0]:hits[0] + len(o)] = n + b'\0' * (len(o) - len(n))
        print('patchstr: %r -> %r at %#x' % (old, new, hits[0]))
    open(dst, 'wb').write(buf)


def dylib_ordinal(m, install_name):
    n = 0
    for cmd, off, size in m.cmds:
        if cmd in (0xc, 0x18 | LC_REQ_DYLD, 0x1f | LC_REQ_DYLD, 0x23 | LC_REQ_DYLD):
            n += 1
            so = struct.unpack_from('<I', m.buf, off + 8)[0]
            if m.buf[off + so:off + size].split(b'\0')[0].decode() == install_name:
                return n
    raise SystemExit('%s is not a dependency' % install_name)


def rebind(src, dst, target, symbols):
    """Point lazy binds of `symbols` at the dependency named `target`."""
    m = MachO(src)
    ordinal = dylib_ordinal(m, target)
    if ordinal > 15:
        raise SystemExit('ordinal %d does not fit an IMM opcode' % ordinal)
    info = m.find(LC_DYLD_INFO_ONLY) or m.find(LC_DYLD_INFO)
    _, off, _ = info[0]
    lb_off, lb_size = struct.unpack_from('<2I', m.buf, off + 8 + 24)
    want = {s.encode() for s in symbols}
    done = set()
    p, end, ord_pos = lb_off, lb_off + lb_size, None
    while p < end:
        b = m.buf[p]; op = b & 0xf0
        if op == 0x10:
            ord_pos = p; p += 1
        elif op == 0x20:
            ord_pos = p; p += 1; _, p = uleb(m.buf, p)
        elif op == 0x40:
            e = m.buf.index(0, p + 1)
            name = bytes(m.buf[p + 1:e])
            if name in want:
                if ord_pos is None or m.buf[ord_pos] & 0xf0 != 0x10:
                    raise SystemExit('%s: ordinal is not an IMM opcode' % name.decode())
                m.buf[ord_pos] = 0x10 | ordinal
                done.add(name)
            p = e + 1
        elif op == 0x70:
            p += 1; _, p = uleb(m.buf, p)
        elif op in (0x60, 0x80, 0xa0):
            p += 1; _, p = uleb(m.buf, p)
        elif op == 0x00:
            ord_pos = None; p += 1
        else:
            p += 1
    missing = want - done
    if missing:
        raise SystemExit('not found in lazy binds: %s' % ', '.join(s.decode() for s in missing))
    # keep the symbol table's two-level ordinal (n_desc high byte) consistent
    for cmd, off, _ in m.find(0x2):  # LC_SYMTAB
        symoff, nsyms, stroff, _ = struct.unpack_from('<4I', m.buf, off + 8)
        for i in range(nsyms):
            e = symoff + i * 16
            strx, ntype, _sect, desc = struct.unpack_from('<IBBH', m.buf, e)
            if ntype & 0x0e != 0 or not ntype & 0x01:  # undefined external only
                continue
            name = bytes(m.buf[stroff + strx:m.buf.index(0, stroff + strx)])
            if name in want:
                struct.pack_into('<H', m.buf, e + 6, (desc & 0x00ff) | (ordinal << 8))
    open(dst, 'wb').write(m.buf)
    print('rebind: %s -> ordinal %d (%s)' % (', '.join(symbols), ordinal, target))


def info(src):
    m = MachO(src)
    print('filetype %d ncmds %d sizeofcmds %d flags %#x first section at %#x'
          % (m.filetype, m.ncmds, m.sizeofcmds, m.flags, m.first_section_offset()))
    for cmd, off, size in m.cmds:
        extra = ''
        if cmd == LC_SEGMENT_64:
            extra = m.buf[off + 8:off + 24].rstrip(b'\0').decode()
        elif cmd in (0xc, 0xd, 0x18 | LC_REQ_DYLD, 0x1c | LC_REQ_DYLD, 0xe):
            so = struct.unpack_from('<I', m.buf, off + 8)[0]
            extra = m.buf[off + so:off + size].split(b'\0')[0].decode()
        print('  %-24s %5d %s' % (NAMES.get(cmd, hex(cmd)), size, extra))


if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    c = sys.argv[1]
    if c == 'exe2dylib' and len(sys.argv) == 5:
        exe2dylib(*sys.argv[2:5])
    elif c == 'patchstr' and len(sys.argv) >= 5:
        patchstr(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif c == 'rebind' and len(sys.argv) >= 6:
        rebind(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
    elif c == 'info':
        info(sys.argv[2])
    else:
        raise SystemExit(__doc__)
