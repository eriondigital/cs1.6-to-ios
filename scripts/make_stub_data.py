#!/usr/bin/env python3
"""
Writes placeholder "game files" for automated tests, so the engine can boot in the
iOS Simulator without any of Valve's data:
  valve/gfx.wad          one blank 'conchars' lump (the only file the engine refuses to start without)
  cstrike/liblist.gam    minimal game description
  cstrike/valve.rc       just "stuffcmds", so +map in the launch options runs
Everything else (textures, sounds, models) will be reported missing by the engine,
which is expected; the point is to exercise the code, libraries and file layout.

usage: make_stub_data.py [--zips] [--delta <delta.lst>] <Documents dir>
       default   write the two folders
       --zips    write them as zips the way players might:
                   valve.zip      -> valve/gfx.wad (top folder)
                   cstrike_2.zip  -> liblist.gam   (no top folder, odd name)
       --delta   also add this delta.lst (network field layout the engine needs to start a game;
                 CI passes the one shipped with ReGameDLL_CS)
"""
import os
import struct
import sys
import zipfile


def gfx_wad():
    # WAD3 with a single 128x128 qpic called "conchars"
    w = h = 128
    pic = struct.pack('<ii', w, h) + bytes(w * h) + struct.pack('<h', 256) + bytes(768) + b'\0\0'
    data_ofs = 12
    dir_ofs = data_ofs + len(pic)
    entry = struct.pack('<iiibbh', data_ofs, len(pic), len(pic), 0x42, 0, 0) + b'conchars'.ljust(16, b'\0')
    return b'WAD3' + struct.pack('<ii', 1, dir_ofs) + pic + entry


# the engine only runs "+command" launch options once a valve.rc calls stuffcmds
VALVE_RC = b'stuffcmds\n'

LIBLIST = ('game "Counter-Strike"\n'
           'type "multiplayer_only"\n'
           'cldll "1"\n'
           'gamedll "dlls\\mp.dll"\n'
           'gamedll_linux "dlls/cs.so"\n'
           'gamedll_osx "dlls/cs.dylib"\n'
           'trainmap "tr_1"\n').encode()

args = sys.argv[1:]
as_zips = '--zips' in args
delta = None
if '--delta' in args:
    i = args.index('--delta')
    with open(args[i + 1], 'rb') as f:
        delta = f.read()
    del args[i:i + 2]
root = [a for a in args if a != '--zips'][0]
os.makedirs(root, exist_ok=True)

if as_zips:
    with zipfile.ZipFile(os.path.join(root, 'valve.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('valve/', b'')
        z.writestr('valve/gfx.wad', gfx_wad())
    with zipfile.ZipFile(os.path.join(root, 'cstrike_2.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('liblist.gam', LIBLIST)
        z.writestr('valve.rc', VALVE_RC)
        if delta:
            z.writestr('delta.lst', delta)
        z.writestr('__MACOSX/._liblist.gam', b'macOS metadata that must be skipped')
    print('placeholder game zips written to', root)
else:
    os.makedirs(os.path.join(root, 'valve'), exist_ok=True)
    os.makedirs(os.path.join(root, 'cstrike'), exist_ok=True)
    with open(os.path.join(root, 'valve', 'gfx.wad'), 'wb') as f:
        f.write(gfx_wad())
    with open(os.path.join(root, 'cstrike', 'liblist.gam'), 'wb') as f:
        f.write(LIBLIST)
    with open(os.path.join(root, 'cstrike', 'valve.rc'), 'wb') as f:
        f.write(VALVE_RC)
    if delta:
        with open(os.path.join(root, 'cstrike', 'delta.lst'), 'wb') as f:
            f.write(delta)
    print('placeholder game data written to', root)
