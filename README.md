# Counter-Strike 1.6 for iOS

A native iPhone and iPad port of Counter-Strike 1.6. It's built from open-source projects:
the [Xash3D FWGS](https://github.com/FWGS/xash3d-fwgs) engine, [cs16-client](https://github.com/Velaron/cs16-client),
[ReGameDLL_CS](https://github.com/rehlds/ReGameDLL_CS) for the game rules, and [YaPB](https://github.com/yapb/yapb) for bots.

- Plays offline against bots, or online on regular CS 1.6 servers
- Touch controls (editable in Options > Touch) and MFi / Xbox / PlayStation controllers
- Runs natively on arm64 with OpenGL ES

**No game files are included.** The app is only the engine and game code. You need your own copy of
Counter-Strike 1.6 (it's on Steam). The app reads the original `valve` and `cstrike` folders.

## Download

Get **CS16-iOS.ipa** from the [latest release](../../releases/latest). It's built by GitHub Actions from this repo on every push.

## Install

The IPA is unsigned, so install it with a sideloading tool:

| Tool | Works on | Notes |
|---|---|---|
| [Sideloadly](https://sideloadly.io) | Windows / macOS + any iOS | Sign in with your Apple ID. With a free Apple ID the app must be re-installed every 7 days (your game files stay). |
| [AltStore](https://altstore.io) / [SideStore](https://sidestore.io) | any iOS | Same 7-day limit with a free Apple ID, but it refreshes itself. |
| [TrollStore](https://github.com/opa334/TrollStore) | iOS 14.0 – 16.6.1, 17.0 | Permanent install, no re-signing. |

With a free Apple ID you may also need to trust the certificate (Settings > General > VPN & Device Management)
and on iOS 16+ turn on Developer Mode (Settings > Privacy & Security > Developer Mode).

## Add your game files

1. **Open the app once.** It will say the game files are missing. That's expected: this creates the
   app's folder in the Files app.
2. On your computer, find the Counter-Strike 1.6 install. With Steam it's
   `C:\Program Files (x86)\Steam\steamapps\common\Half-Life\` on Windows.
3. Copy the **`valve`** and **`cstrike`** folders to the iPhone, into
   **Files > On My iPhone > CS 1.6**. Some easy ways:
   - Zip both folders, send the zip to the phone (AirDrop, iCloud Drive, Google Drive, a USB cable with
     Finder / iTunes file sharing), move it into the CS 1.6 folder and tap it to unzip.
   - On a Mac, drag the folders onto the app in Finder > your iPhone > Files.
4. Open the app again and tap **Check Again** if the message is still showing.

You should end up with:

```
On My iPhone
└── CS 1.6
    ├── valve
    │   ├── gfx.wad
    │   └── ...
    └── cstrike
        ├── liblist.gam
        ├── maps
        └── ...
```

It's fine if the two folders sit inside one extra folder, for example `CS 1.6/Counter-Strike 1.6/valve`. The app finds them.

## Playing

- **Bots:** start a game from *New Game / Create Server*. YaPB bots join on their own. Open the console
  (or bind keys) for commands like `yb add`, `yb kickall` or `yb quota 6`.
- **Online:** use *Find Servers*, or the console: `connect ip:port`. Allow microphone access if you want voice chat.
- **Touch layout:** *Options > Touch* lets you move, resize and add buttons.
- **Renderer:** the default is OpenGL ES 1 (most compatible). `gles3compat` usually looks and runs better. Switch in
  *Options > Video* or with the launch option below.

### Launch options

Put a file named `commandline.txt` in the CS 1.6 folder with extra engine options, for example:

```
-ref gles3compat
```

Without bots: `-dll @cs`.

### Something went wrong?

- **No sound:** check the silent switch / Action button. The game follows the phone's silent mode.
- **"Game files needed" even though you copied them:** make sure both `valve` and `cstrike` are folders (not zips)
  inside *On My iPhone > CS 1.6*, and that the copy has finished.
- **Crashes or missing textures:** the engine writes `engine.log` into the CS 1.6 folder on every start.
  Open an issue with it attached.

## How the port works

The engine already ships with iOS support. This repo adds what was missing to get Counter-Strike running
on it, and a pipeline that builds an IPA:

- **`ios/launcher.m`** replaces the engine's "launch options" dialog. It starts straight into Counter-Strike with
  bots, checks for the game files and explains what to do when they're missing, and finds them in a subfolder too.
- **`scripts/apply_patches.py`** applies two small fixes to the upstream code:
  - *YaPB* looks for the CS game library in the app bundle (`XASH3D_GAMELIBDIR`), as it already did on Android.
    On iOS, code can only load from the signed bundle, while the working directory is Documents.
  - *ReGameDLL_CS* only searched the working directory for the engine's `filesystem_stdio`. When that failed
    it continued with a null pointer and crashed on every map load. It now also searches next to the executable.
- **`scripts/build.sh`** builds SDL2, the engine and the CS libraries for iOS. It installs the libraries under
  the names the engine expects on iOS (`client_ios_arm64.dylib`, ...), and assembles and ad-hoc signs `CS16.app`.
- **`scripts/verify_bundle.py`** checks that every library is present and arm64, and that all dynamic-library
  dependencies resolve inside the bundle.
- **`scripts/sim_test.sh`** boots the build in the iOS Simulator with placeholder data (no Valve files) and
  takes screenshots. The workflow uploads them as the `simulator-test` artifact.

### Building it yourself

GitHub Actions does it on every push (see `.github/workflows/build.yml`). On a Mac with Xcode, CMake and Python 3:

```sh
git clone https://github.com/eriondigital/cs1.6-to-ios && cd cs1.6-to-ios
git clone --recursive https://github.com/FWGS/xash3d-fwgs
git clone --recursive https://github.com/Velaron/cs16-client
bash scripts/build.sh device      # -> out/device/CS16-iOS.ipa
```

The upstream commits used by CI are pinned in the workflow file.

## Credits and licenses

- [Xash3D FWGS](https://github.com/FWGS/xash3d-fwgs) engine (GPL-3.0). `ios/launcher.m` is based on its iOS launch dialog.
- [cs16-client](https://github.com/Velaron/cs16-client) by Velaron: client, menu and mobile extras.
- [ReGameDLL_CS](https://github.com/rehlds/ReGameDLL_CS) (GPL-3.0), [YaPB](https://github.com/yapb/yapb) (MIT), [SDL](https://libsdl.org) (zlib).

Code in this repository is GPL-3.0. Counter-Strike and Half-Life are trademarks of Valve Corporation.
This project is not affiliated with or endorsed by Valve. Use it with a copy of the game you own.
