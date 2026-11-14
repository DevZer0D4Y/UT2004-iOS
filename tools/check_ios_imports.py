#!/usr/bin/env python3
"""List imports of macOS arm64 binaries that the iOS SDK does not export.

usage: check_ios_imports.py <iPhoneOS.sdk> <binary> [...]
Symbols from our own dylibs (modules, SDL3, OpenAL, shims) are skipped.
"""
import os
import re
import subprocess
import sys

OWN = re.compile(r'^(Core|Engine|IpDrv|XGame|SDLDrv|Fire|Editor|XInterface|UWeb|UTV2004|OpenGLDrv|'
                 r'Onslaught|MetalDrv|AntiDrv|ALAudio|UT2004Main|libSDL3|libopenal.*|libShim.*)$')
LIB_TBDS = {
    'libSystem': ['usr/lib/libSystem.B.tbd', 'usr/lib/system/*'],
    'libc++': ['usr/lib/libc++.1.tbd', 'usr/lib/libc++abi.tbd'],
    'libiconv': ['usr/lib/libiconv.2.tbd'],
    'libobjc': ['usr/lib/libobjc.A.tbd'],
}


def tbd_text(sdk, lib):
    pats = LIB_TBDS.get(lib, ['System/Library/Frameworks/%s.framework/%s.tbd' % (lib, lib)])
    text = ''
    for p in pats:
        full = os.path.join(sdk, p)
        if full.endswith('*'):
            d = os.path.dirname(full)
            if not os.path.isdir(d):
                continue
            for f in os.listdir(d):
                if f.endswith('.tbd'):
                    text += open(os.path.join(d, f), errors='replace').read()
        elif os.path.exists(full):
            text += open(full, errors='replace').read()
        else:
            return None
    return text


def tbd_name(sym):
    """.tbd files list Objective-C classes/ivars without the symbol prefix."""
    for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_', '_OBJC_EHTYPE_$_', '_OBJC_IVAR_$_'):
        if sym.startswith(prefix):
            return sym[len(prefix):]
    return sym


def main():
    sdk = sys.argv[1]
    cache = {}
    bad = 0
    for binary in sys.argv[2:]:
        out = subprocess.run(['nm', '-m', '-u', binary], capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = re.search(r'external (\S+) \(from ([^)]+)\)', line)
            if not m:
                continue
            sym, lib = m.group(1), m.group(2)
            weak = 'weak' in line
            if OWN.match(lib) or sym == 'dyld_stub_binder':
                continue
            if lib not in cache:
                cache[lib] = tbd_text(sdk, lib)
            text = cache[lib]
            if text is None:
                print('%s: %s from %s (no iOS library)%s' % (os.path.basename(binary), sym, lib,
                                                             ' [weak]' if weak else ''))
                bad += 1
            elif not re.search(r"[\s,\['\"]%s[\s,\]'\"]" % re.escape(tbd_name(sym)), text):
                print('%s: %s from %s (missing on iOS)%s' % (os.path.basename(binary), sym, lib,
                                                            ' [weak]' if weak else ''))
                bad += 1
    print('%d problem imports' % bad)


if __name__ == '__main__':
    main()
