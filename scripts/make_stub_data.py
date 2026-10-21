#!/usr/bin/env python3
"""
Writes placeholder "game files" for automated tests, so the engine can boot in the
iOS Simulator without any of Valve's data:
  valve/gfx.wad          one blank 'conchars' lump (the only file the engine refuses to start without)
  cstrike/liblist.gam    minimal game description
Everything else (textures, sounds, models) will be reported missing by the engine,
which is expected; the point is to exercise the code, libraries and file layout.

usage: make_stub_data.py <Documents dir>
"""
import os
import struct
import sys

root = sys.argv[1]
os.makedirs(os.path.join(root, 'valve'), exist_ok=True)
os.makedirs(os.path.join(root, 'cstrike'), exist_ok=True)

# WAD3 with a single 128x128 qpic called "conchars"
w = h = 128
pic = struct.pack('<ii', w, h) + bytes(w * h) + struct.pack('<h', 256) + bytes(768) + b'\0\0'
data_ofs = 12
dir_ofs = data_ofs + len(pic)
entry = struct.pack('<iiibbh', data_ofs, len(pic), len(pic), 0x42, 0, 0) + b'conchars'.ljust(16, b'\0')
with open(os.path.join(root, 'valve', 'gfx.wad'), 'wb') as f:
    f.write(b'WAD3' + struct.pack('<ii', 1, dir_ofs) + pic + entry)

with open(os.path.join(root, 'cstrike', 'liblist.gam'), 'w') as f:
    f.write('game "Counter-Strike"\n'
            'type "multiplayer_only"\n'
            'cldll "1"\n'
            'gamedll "dlls\\mp.dll"\n'
            'gamedll_linux "dlls/cs.so"\n'
            'gamedll_osx "dlls/cs.dylib"\n'
            'trainmap "tr_1"\n')

print('placeholder game data written to', root)
