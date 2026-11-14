#!/usr/bin/env python3
"""Print UTF-32LE (wchar_t on Apple) strings in a binary, optionally filtered.

usage: wstrings.py <binary> [regex]
"""
import re
import sys


def main():
    data = open(sys.argv[1], 'rb').read()
    pat = re.compile(sys.argv[2], re.I) if len(sys.argv) > 2 else None
    # runs of >= 4 printable chars, each encoded as 4 bytes little endian
    for m in re.finditer(rb'(?:[\x20-\x7e]\x00\x00\x00){4,}', data):
        if m.start() % 4:
            continue
        s = m.group().decode('utf-32-le')
        if pat is None or pat.search(s):
            print('%#x %s' % (m.start(), s))


if __name__ == '__main__':
    main()
