#!/usr/bin/env python3
"""
Repacks cs16-client's extras.pk3 without the game content that comes from the
original game (training maps, bot voice lines, menu sounds, bot databases, the
menu splash artwork).
Players already have those files in their own cstrike/valve folders, and this
project publishes builds that should only contain open-source parts.
Touch layouts, configs, menu buttons and titles, and YaPB data are kept.

usage: repack_extras.py <extras.pk3 in> <extras.pk3 out>
"""
import sys
import zipfile

DROP_PREFIXES = ('sound/', 'maps/', 'media/')
DROP_FILES = {'BotChatter.db', 'BotProfile.db', 'gfx/shell/splash.bmp'}  # splash.bmp: game artwork

src, dst = sys.argv[1], sys.argv[2]
kept = dropped = 0
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as zout:
    for info in zin.infolist():
        name = info.filename
        if name.startswith(DROP_PREFIXES) or name in DROP_FILES:
            dropped += 1
            continue
        zout.writestr(info, zin.read(name))
        kept += 1
print(f'extras.pk3: kept {kept} files, left out {dropped} game content files')
