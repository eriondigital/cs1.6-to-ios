#!/usr/bin/env python3
"""
Applies this port's changes to the upstream sources.

Plain string replacements instead of .patch files: some upstream files are
checked out with CRLF line endings (ReGameDLL_CS .gitattributes), which breaks
`git apply` depending on the platform. Every replacement must match exactly once,
and running the script twice is harmless.

usage: apply_patches.py <xash3d-fwgs dir> <cs16-client dir> <this repo dir>
"""
import os
import shutil
import sys


def patch(path, old, new, what):
    with open(path, 'rb') as f:
        data = f.read().decode('utf-8')

    crlf = '\r\n' in data
    if crlf:
        data = data.replace('\r\n', '\n')

    if new in data:
        print(f'[skip] {what}: already applied')
        return

    count = data.count(old)
    if count != 1:
        sys.exit(f'[fail] {what}: expected 1 match in {path}, found {count}')

    data = data.replace(old, new)
    if crlf:
        data = data.replace('\n', '\r\n')

    with open(path, 'wb') as f:
        f.write(data.encode('utf-8'))
    print(f'[ok]   {what}')


def main():
    xash, cs16, repo = sys.argv[1:4]

    # 1. Our launcher replaces the stock "launch options" dialog. The engine's
    #    build compiles every .c/.m file in platform/ios, so the zip importer
    #    only needs to be dropped next to it.
    ios_dir = os.path.join(xash, 'engine', 'platform', 'ios')
    shutil.copyfile(os.path.join(repo, 'ios', 'launcher.m'), os.path.join(ios_dir, 'launchdialog.m'))
    for name in ('zipimport.c', 'zipimport.h'):
        shutil.copyfile(os.path.join(repo, 'ios', name), os.path.join(ios_dir, name))
    print('[ok]   engine: iOS launcher and zip importer added')

    # 1b. waf always targets arm64 for iOS; let the simulator build target the host
    #     architecture (x86_64 on Intel Macs) through IOS_TARGET_ARCH.
    patch(os.path.join(xash, 'scripts', 'waifulib', 'xcompile.py'),
          "\t\tself.target = '--target=aarch64-apple-ios'",
          "\t\tself.target = '--target=%s-apple-ios' % os.environ.get('IOS_TARGET_ARCH', 'aarch64')",
          'waf: configurable iOS target architecture')

    # 2. YaPB: look for the CS server library in XASH3D_GAMELIBDIR on iOS too, not
    #    only on Android. On iOS the libraries live in the signed app bundle while
    #    the current directory is Documents.
    patch(os.path.join(cs16, '3rdparty', 'yapb', 'src', 'engine.cpp'),
          '''      if (plat.android) {
         // this will be removed as soon as mod downloader will be implemented on engine side
         auto gamelibdir = plat.env ("XASH3D_GAMELIBDIR");''',
          '''      // android and ios ports keep game libraries outside of the (writable) game directory,
      // their launchers tell us where via XASH3D_GAMELIBDIR
      if (plat.android || *plat.env ("XASH3D_GAMELIBDIR") != '\\0') {
         // this will be removed as soon as mod downloader will be implemented on engine side
         auto gamelibdir = plat.env ("XASH3D_GAMELIBDIR");''',
          'yapb: XASH3D_GAMELIBDIR on every platform')

    # 3. ReGameDLL: filesystem_stdio is searched only in the current directory.
    #    On iOS that's Documents, the library is in the app bundle next to the
    #    executable, so the lookup failed, g_pFileSystem stayed NULL and the
    #    server crashed in BotPhraseManager::Initialize on every map load.
    interface_cpp = os.path.join(cs16, '3rdparty', 'ReGameDLL_CS', 'regamedll', 'public', 'interface.cpp')
    patch(interface_cpp,
          '''// Purpose: Loads a DLL/component from disk and returns a handle to it''',
          '''#if !defined(_WIN32) && !defined(__ANDROID__)
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

// Directory of the running executable. The engine keeps its libraries
// (filesystem_stdio among them) next to it, which isn't always the current
// directory: on iOS the code lives in the app bundle and cwd is Documents.
static bool Sys_GetExecutableDir(char *out, size_t size)
{
#if defined(__APPLE__)
	uint32_t len = (uint32_t)size;
	if (_NSGetExecutablePath(out, &len) != 0)
		return false;
#else
	ssize_t len = readlink("/proc/self/exe", out, size - 1);
	if (len <= 0)
		return false;
	out[len] = '\\0';
#endif
	char *slash = strrchr(out, '/');
	if (!slash)
		return false;
	*slash = '\\0';
	return true;
}
#endif

// Purpose: Loads a DLL/component from disk and returns a handle to it''',
          'regamedll: executable directory helper')

    patch(interface_cpp,
          '''		_snprintf(str, sizeof(str), "%s.so", szAbsoluteModuleName);
		hDLL = dlopen(str, RTLD_NOW);
#endif
	}

	return reinterpret_cast<CSysModule *>(hDLL);''',
          '''		_snprintf(str, sizeof(str), "%s.so", szAbsoluteModuleName);
		hDLL = dlopen(str, RTLD_NOW);
#endif
	}

#if !defined(_WIN32) && !defined(__ANDROID__)
	if (!hDLL && pModuleName[0] != '/')
	{
		char szExeDir[1024];
		if (Sys_GetExecutableDir(szExeDir, sizeof(szExeDir)))
		{
			_snprintf(szAbsoluteModuleName, sizeof(szAbsoluteModuleName), "%s/%s", szExeDir, pModuleName);
			hDLL = dlopen(szAbsoluteModuleName, RTLD_NOW);
		}
	}
#endif

	return reinterpret_cast<CSysModule *>(hDLL);''',
          'regamedll: load filesystem_stdio from the executable directory')


if __name__ == '__main__':
    main()
