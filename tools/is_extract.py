#!/usr/bin/env python3
"""Minimal InstallShield (v5 / v6+) cabinet extractor.

Reads dataN.hdr + dataN.cab volumes (possibly spread over several
directories, e.g. Disk1..Disk5 of a mounted ISO) and writes files grouped by
InstallShield file group: <out>/<group>/<dir>/<file>.

usage: is_extract.py list    <data1.hdr> <cab dir> [<cab dir> ...]
       is_extract.py extract <data1.hdr> <out dir> --groups A,B --dirs <cab dir> ...
"""
import argparse
import hashlib
import os
import struct
import sys
import zlib

FILE_SPLIT, FILE_OBFUSCATED, FILE_COMPRESSED, FILE_INVALID = 1, 2, 4, 8
MAX_GROUPS = 71


def u16(b, o): return struct.unpack_from('<H', b, o)[0]
def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]


def cstr(b, o):
    e = b.index(b'\0', o)
    return b[o:e].decode('latin-1')


class Header:
    def __init__(self, path):
        self.data = d = open(path, 'rb').read()
        sig, version, _volinfo, self.cdo, cds = struct.unpack_from('<5I', d, 0)
        if sig != 0x28635349:
            raise SystemExit('not an InstallShield header: %s' % path)
        if version >> 24 == 1:
            major = (version >> 12) & 0xf
        elif version >> 24 in (2, 4):
            major = version & 0xffff
            major = major // 100 if major else 0
        else:
            major = 5
        self.major = major
        p = self.cdo + 0xc
        self.fto = u32(d, p); p += 8
        self.fts = u32(d, p); p += 8
        self.dir_count = u32(d, p); p += 12
        self.file_count = u32(d, p); p += 4
        self.fto2 = u32(d, p); p += 4
        p += 0xe
        self.group_offsets = [u32(d, p + 4 * i) for i in range(MAX_GROUPS)]
        base = self.cdo + self.fto
        self.table = [u32(d, base + 4 * i) for i in range(self.dir_count + self.file_count)]

    def dir_name(self, i):
        return cstr(self.data, self.cdo + self.fto + self.table[i])

    def file(self, i):
        d = self.data
        f = {}
        if self.major in (0, 5):
            p = self.cdo + self.fto + self.table[self.dir_count + i]
            f['volume'] = 1
            f['name_offset'] = u32(d, p); p += 4
            f['dir'] = u32(d, p); p += 4
            f['flags'] = u16(d, p); p += 2
            f['expanded'] = u32(d, p); p += 4
            f['compressed'] = u32(d, p); p += 4
            p += 0x14
            f['offset'] = u32(d, p); p += 4
            f['md5'] = d[p:p + 16] if self.major == 5 else None
        else:
            p = self.cdo + self.fto + self.fto2 + i * 0x57
            f['flags'] = u16(d, p)
            f['expanded'] = u64(d, p + 2)
            f['compressed'] = u64(d, p + 10)
            f['offset'] = u64(d, p + 18)
            f['md5'] = d[p + 26:p + 42]
            f['name_offset'] = u32(d, p + 58)
            f['dir'] = u16(d, p + 62)
            f['volume'] = u16(d, p + 0x55)
        f['name'] = cstr(d, self.cdo + self.fto + f['name_offset'])
        return f

    def groups(self):
        d = self.data
        out = []
        for off in self.group_offsets:
            while off:
                p = self.cdo + off
                _name_off, desc_off, nxt = struct.unpack_from('<3I', d, p)
                q = self.cdo + desc_off
                name = cstr(d, self.cdo + u32(d, q))
                q += 4 + (0x48 if self.major <= 5 else 0x12)
                first, last = u32(d, q), u32(d, q + 4)
                out.append((name, first, last))
                off = nxt
        return out


class Volumes:
    def __init__(self, major, dirs):
        self.major = major
        self.dirs = dirs
        self.cache = {}

    def path(self, n):
        for d in self.dirs:
            for cand in ('data%d.cab' % n, 'DATA%d.CAB' % n):
                p = os.path.join(d, cand)
                if os.path.exists(p):
                    return p
        raise SystemExit('volume data%d.cab not found in %s' % (n, self.dirs))

    def header(self, n):
        if n not in self.cache:
            fh = open(self.path(n), 'rb')
            b = fh.read(20 + 0x40)
            if u32(b, 0) != 0x28635349:
                raise SystemExit('bad cab signature in volume %d' % n)
            p = 20
            if self.major <= 5:
                h = dict(data_offset=u32(b, p), first_index=u32(b, p + 8), last_index=u32(b, p + 12),
                         first_offset=u32(b, p + 16), first_exp=u32(b, p + 20), first_comp=u32(b, p + 24),
                         last_offset=u32(b, p + 28), last_exp=u32(b, p + 32), last_comp=u32(b, p + 36))
            else:
                h = dict(data_offset=u32(b, p), first_index=u32(b, p + 8), last_index=u32(b, p + 12),
                         first_offset=u32(b, p + 16), first_exp=u32(b, p + 24), first_comp=u32(b, p + 32),
                         last_offset=u32(b, p + 40), last_exp=u32(b, p + 48), last_comp=u32(b, p + 56))
            self.cache[n] = (fh, h)
        return self.cache[n]


def read_file_bytes(vols, index, f):
    """Yield the stored (possibly compressed) byte stream of file `index`."""
    vol = f['volume']
    compressed = bool(f['flags'] & FILE_COMPRESSED)
    total = f['compressed'] if compressed else f['expanded']
    got = 0
    while got < total:
        fh, h = vols.header(vol)
        if f['flags'] & FILE_SPLIT:
            if index == h['last_index'] and h['last_offset'] != 0x7FFFFFFF:
                off, n = h['last_offset'], (h['last_comp'] if compressed else h['last_exp'])
            elif index == h['first_index']:
                off, n = h['first_offset'], (h['first_comp'] if compressed else h['first_exp'])
            else:
                raise SystemExit('split file %d not in volume %d' % (index, vol))
        else:
            off, n = f['offset'], total
        n = min(n, total - got)
        fh.seek(off)
        left = n
        while left:
            chunk = fh.read(min(left, 1 << 20))
            if not chunk:
                raise SystemExit('short read in volume %d' % vol)
            left -= len(chunk)
            yield chunk
        got += n
        vol += 1


def extract_file(vols, index, f, out_path):
    stream = bytearray()
    md5 = hashlib.md5()
    written = 0
    tmp = out_path + '.part'
    with open(tmp, 'wb') as o:
        if f['flags'] & FILE_COMPRESSED:
            for chunk in read_file_bytes(vols, index, f):
                stream += chunk
                # blocks: uint16 length + raw deflate data
                while len(stream) >= 2:
                    n = u16(stream, 0)
                    if len(stream) < 2 + n:
                        break
                    block = bytes(stream[2:2 + n])
                    del stream[:2 + n]
                    d = zlib.decompressobj(-15)
                    data = d.decompress(block) + d.flush()
                    o.write(data); md5.update(data); written += len(data)
            if stream:
                raise SystemExit('trailing compressed bytes in %s' % out_path)
        else:
            for chunk in read_file_bytes(vols, index, f):
                o.write(chunk); md5.update(chunk); written += len(chunk)
    if written != f['expanded']:
        raise SystemExit('%s: size %d != expected %d' % (out_path, written, f['expanded']))
    if f.get('md5') and any(f['md5']) and md5.digest() != f['md5']:
        raise SystemExit('%s: md5 mismatch' % out_path)
    os.replace(tmp, out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['list', 'extract'])
    ap.add_argument('hdr')
    ap.add_argument('out', nargs='?')
    ap.add_argument('--dirs', nargs='+', default=[])
    ap.add_argument('--groups', default='')
    a = ap.parse_args()
    h = Header(a.hdr)
    groups = h.groups()
    if a.mode == 'list':
        print('InstallShield major %d, %d dirs, %d files' % (h.major, h.dir_count, h.file_count))
        for name, first, last in groups:
            size = 0
            for i in range(first, last + 1):
                f = h.file(i)
                if not f['flags'] & FILE_INVALID and f['offset']:
                    size += f['expanded']
            print('%-28s files %5d  %8.1f MB' % (name, last - first + 1, size / 1e6))
        return
    want = set(filter(None, a.groups.split(',')))
    vols = Volumes(h.major, a.dirs or [os.path.dirname(a.hdr)])
    for name, first, last in groups:
        if want and name not in want:
            continue
        n = 0
        for i in range(first, last + 1):
            f = h.file(i)
            if f['flags'] & FILE_INVALID or not f['offset']:
                continue
            d = h.dir_name(f['dir']).replace('\\', '/').strip('/')
            out_dir = os.path.join(a.out, name, d) if d else os.path.join(a.out, name)
            os.makedirs(out_dir, exist_ok=True)
            out_path = os.path.join(out_dir, f['name'])
            if os.path.exists(out_path) and os.path.getsize(out_path) == f['expanded']:
                continue
            extract_file(vols, i, f, out_path)
            n += 1
        print('%s: %d files extracted' % (name, n), flush=True)


if __name__ == '__main__':
    main()
