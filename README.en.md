<p align="center"><img src="docs/icon.png" width="128" alt="Spektra Cam icon"></p>

<h1 align="center">Spektra Cam</h1>

<p align="center">Shoot on iPhone, develop with SpektraLab's physical film engine.</p>

<p align="center"><a href="README.md">简体中文</a> · <b>English</b></p>

<p align="center"><b>Current version:</b> 2.1.8 (Build 16) · <b>Requires:</b> iOS 18+</p>

<p align="center"><img src="https://img.shields.io/badge/iOS-18%2B-1f6feb?style=flat-square" alt="iOS 18+"> <img src="https://img.shields.io/badge/UI-SwiftUI-f05138?style=flat-square" alt="UI SwiftUI"> <img src="https://img.shields.io/badge/Engine-SpektraLab%202.4.1-8e44ad?style=flat-square" alt="Engine SpektraLab 2.4.1"> <img src="https://img.shields.io/badge/Version-2.1.8-555555?style=flat-square" alt="Version 2.1.8"> <img src="https://img.shields.io/badge/License-GPL--3.0-2e7d32?style=flat-square" alt="License GPL-3.0"></p>

<p align="center"><a href="../../releases/latest">Download</a> · <a href="#installation">Install guide</a> · <a href="#5-add-the-spektra-cam-source">Source</a> · <a href="#building-from-source">Build from source</a></p>

**Spektra Cam is an unofficial iPhone port of [SpektraLab](https://github.com/JamesQiu2005/SpektraLab), the Mac film-developing app.** It uses the same physical film engine — film exposure, dye layers, grain, halation, the enlarger and the paper, computed all the way through rather than a LUT laid over the photo — and adds a camera, a light table and more on the iPhone. It started from the iOS community port [Minerchu/SpektraLab-iOS](https://github.com/Minerchu/SpektraLab-iOS) 1.2.0 and has since been redesigned and greatly extended. Original credits and upstream links are kept; it is not an official SpektraLab app.

If the project helps you, a **Star** is welcome; found a problem or have an idea? Open an [Issue](../../issues).

## Status

- Current version **2.1.8 (Build 16)**, distributed as an unsigned IPA in GitHub Releases and installed by self-signing with SideStore; or add the [source](#5-add-the-spektra-cam-source) and update from inside SideStore.
- The film engine is upstream SpektraLab **2.4.1**: the same RAW develops to the same colour in the Mac app and in Spektra Cam (compared photo by photo).
- Done: camera (ProRAW / single-frame RAW / HEIF, the iPhone 17 square front camera), a darkroom editor in the order light travels, 30 films and 7 papers, film edges and cine gauges, HDR, light table, recipe library, batch export, Chinese and English.
- Tested on iPhone 17 Pro Max (iOS 27) and iPhone 14 Pro (iOS 26.5); other models install fine, but focal lengths, capture sizes, export sizes and HDR brightness are unverified there.
- What changed in each version: see [Releases](../../releases).

## Screenshots

| Negatives | Editor | Camera |
|:---:|:---:|:---:|
| <img src="docs/screenshots/library.png" width="240"> | <img src="docs/screenshots/editor.png" width="240"> | <img src="docs/screenshots/camera.png" width="240"> |
| **Light Table** | **Settings** | **Recipes and Films** |
| <img src="docs/screenshots/lighttable.png" width="240"> | <img src="docs/screenshots/settings.png" width="240"> | <img src="docs/screenshots/recipes.png" width="240"> |

Screenshots of 2.1.7 on an iPhone 17 Pro Max (taken 2026-11-27, Chinese interface; the app also runs in English).

## Features

- **Camera**: ProRAW, single-frame RAW (no multi-frame merging or noise reduction), HEIF; focal lengths per lens (13 / 24 / 48 / 100 / 200 mm on an iPhone 17 Pro Max); the film's colour live in the viewfinder; manual shutter, ISO, exposure compensation and colour temperature; tap to focus, drag for exposure, long-press to lock; level, grid, histogram; the Camera Control and volume buttons as shutter.
- **Front camera**: the iPhone 17's square front sensor — portrait or landscape without turning the phone, 0.6× and 1×, ProRAW.
- **Rolls**: load a film, a recipe or “No film” (the original straight to Photos); the paper follows the roll and the recommended paper you pick is remembered; shots develop in the background without blocking you.
- **Editor**: tools in the order light travels — Frame · Lens · Exposure · Film · Paper · Finish; crop, straighten, rotate, flip; **perspective correction** (vertical, horizontal) and **Auto**, which squares the picture to its own straight lines; white-balance eyedropper; decode curve; global undo / redo; hold to see the original; with No Film only the tools that apply remain.
- **Films and papers**: 30 films (colour negative, slide, cine negative, B&W negative) and 7 papers, by type or by brand; B&W films on Multigrade paper grades 00–5; slides scanned directly; a film comparison grid shows every film at once.
- **Effects**: film edge, sprockets and date back, cine gauges (Super 8 / 16, 35 mm, 65 mm, IMAX); light leaks and edge burn, diffusion filters, lens character (swirl, Petzval, vintage, toy), anti-halation removal.
- **Finish**: light, colour, HSL, curves, colour balance with four wheels, channel mixer, watermarks (dragged, pinched and turned right on the photo); **HDR**: brighter than white on HDR screens, exports carry a gain map.
- **Negatives (library)**: develop straight from the system library (no copy) or import into the app; RAW from every maker (LibRaw fallback), a card's whole DCIM folder, sharing from Photos; grouped by day, pinch to zoom, filters and sorting; slide-to-select, copy and paste recipes, side-by-side compare; **half-frame pairs** (editable again, with a “Half-frame Pair” film edge printing both on one 135 strip); cull and batch export.
- **Light Table**: photos laid on a light box at their negative's real size in millimetres; EDR backlight, lamp, loupe (hold to lean in to 8×), full-screen slideshow; the whole table **exports as one picture** to share.
- **Export**: JPEG / 10-bit HEIF / 16-bit TIFF / PNG in sRGB / Display P3 / Adobe RGB / ProPhoto, three presets; size capped by memory — 48 MP exports at full size (about 31 MP with the film edge on).

## How it works

Spektra Cam is not a filter app. Every photo is developed from scratch by the SpektraLab engine (C++ / Metal, on the iPhone's GPU):

1. **Decode**: RAW is decoded by Core Image into scene-linear ProPhoto data with exactly the Mac app's settings; RAWs Core Image can't read go to LibRaw.
2. **Film exposure**: scene light becomes the exposure of three emulsion layers by the film's spectral sensitivity, then dye density by its characteristic curves; grain, halation and coupler inhibition are computed here at their physical size (micrometres).
3. **Printing**: the enlarger's light passes through the negative onto the paper, which is developed again for the final colour and tone; a slide skips this and is scanned.
4. **Finish**: brightness, colour, curves and other adjustments (Layer 2) run again on the GPU over the developed print — no re-developing needed.

Film and paper data come from the measured profiles of [spektrafilm](https://github.com/andreavolpato/spektrafilm).

## Compared with SpektraLab for Mac

| | Spektra Cam | SpektraLab (Mac) |
|---|---|---|
| Device | iPhone | Mac |
| Developing engine | The same engine (2.4.1), same colour | The original |
| Shooting | Built-in film camera with a live film viewfinder | Develops existing photos |
| Light table | Yes, with EDR backlight and loupe | Yes |
| Full-size film-edge export | Limited by the phone's memory, about 31 MP | Full size |
| Distribution | Unofficial, GitHub, self-signed install | Official |

### Which to use

- Shooting on iPhone and want the film look right away: Spektra Cam.
- Processing many photos on a computer, or need full-size film-edge prints: the Mac app.
- Both develop the same, so you can shoot and look on the iPhone and refine on the Mac later.

## Strengths and limitations

Strengths:

- The same physical engine as the Mac app, not a LUT: changing film, paper or exposure behaves like real film.
- Camera, editor and light table all on the phone; no computer needed.
- Photos, recipes and thumbnails stay on the iPhone; nothing is uploaded.
- Develops photos in your system library directly, without copying or changing the originals.

Limitations:

- Requires iOS 18.0, iPhone only, no iPad layout. Before iOS 26 the interface uses a frosted material instead of Liquid Glass.
- No video.
- With the film edge on, exports top out at about 31 MP (the engine can't render the film edge in bands yet, and a whole render is limited by the phone's memory).
- HDR gain maps are at most 2048 px.
- Sigma Foveon (X3F) and GoPro GPR RAW are not supported; import says so.
- Photos shared from the share menu are imported the next time the app opens (a share extension can't open its app).
- No launching from the Camera Control on the Lock Screen (it needs a Lock Screen extension SideStore can't sign; the code is kept for later).
- SideStore's free signing is bound by Apple's seven-day refresh and limits on apps and App IDs; Spektra Cam uses 2 App IDs (the app and the share extension).

## Before you install

The free route: **iLoader + SideStore (Stable) + LocalDevVPN + Spektra Cam**.

You need:

- An iPhone on iOS 18 or later with a passcode set.
- A Mac, Windows or Linux computer, only for installing SideStore the first time.
- A USB cable that carries data.
- An Apple Account; a free one is fine.
- Wi-Fi. SideStore needs Wi-Fi and LocalDevVPN connected together to install or refresh apps.

Get each tool from its official source:

| Tool | Installed on | Get it from |
|---|---|---|
| iLoader | Computer | [iloader.app](https://iloader.app) |
| SideStore | iPhone, installed by iLoader | [SideStore docs](https://docs.sidestore.io) |
| LocalDevVPN | iPhone | App Store |
| Spektra Cam | iPhone, installed by SideStore | This repository's source or [Releases](../../releases/latest) |

Spektra Cam is not on the App Store or TestFlight. Don't use IPAs from unknown mirrors; they may have been repackaged.

## Installation

### 1. Install LocalDevVPN on the iPhone

1. Install LocalDevVPN from the App Store (it isn't in the China region store; use another region's account).
2. Open it, tap **Connect**, allow the VPN configuration and enter your passcode.
3. Check that it shows connected.

Despite the name it doesn't change your public IP or proxy traffic; it only lets SideStore reach services on the iPhone itself. Turning it on disconnects other proxies or VPNs; you can turn it off after installing or refreshing.

### 2. Install SideStore with iLoader

1. Install iLoader on the computer.
2. Connect and unlock the iPhone; if asked “Trust This Computer?”, choose Trust and enter your passcode.
3. Open iLoader and check that the iPhone is listed. If not, try another cable and make sure Finder, iTunes or Apple Devices sees the phone.
4. Sign in with your Apple Account in iLoader and enter the two-factor code.
5. Select the iPhone and click **Install SideStore (Stable)** — the stable release, not another build.
6. Wait for signing and installation to finish; don't unplug the cable.

If iLoader asks whether to revoke existing certificates, check first whether this Apple Account signs apps for other sideloading tools; revoking can stop those apps from opening.

### 3. Trust the developer and turn on Developer Mode

1. Open Settings › General › VPN & Device Management, choose your Apple Account under Developer App and tap Trust.
2. Open Settings › Privacy & Security › Developer Mode and turn it on.
3. Restart when asked, unlock, and confirm once more.

Developer Mode doesn't need the paid Apple Developer Program; every app installed with SideStore needs it. If Apple says the account has no development team, sign in at [developer.apple.com/register](https://developer.apple.com/register) and accept the agreement — it's free.

### 4. Refresh SideStore once

1. Connect to Wi-Fi and turn on LocalDevVPN.
2. Open SideStore and sign in with the same Apple Account you used in iLoader.
3. Go to **My Apps** and tap **7 DAYS** next to SideStore to refresh it once.
4. If asked to create a new certificate, follow the prompts.

Once this refresh succeeds, SideStore is fully set up and you won't need the computer again.

### 5. Add the Spektra Cam source

1. In SideStore, open **Sources** and tap **＋** at the top right.
2. Paste this address and confirm:

```
https://raw.githubusercontent.com/HLyu3/SpektraCam/main/source.json
```

With the source added, SideStore shows an Update in **My Apps** whenever a new version comes out; one tap updates it, no IPA to download.

### 6. Install Spektra Cam

1. Make sure Wi-Fi and LocalDevVPN are both connected.
2. In SideStore's **Sources**, open the Spektra Cam source and tap **FREE** next to Spektra Cam.
3. Wait for SideStore to sign and install it; keep SideStore open and stay on Wi-Fi and LocalDevVPN.
4. Check that the Spektra Cam icon is on the Home Screen.

**Without the source**: download `SpektraCam-2.1.8-unsigned.ipa` from [Releases](../../releases/latest), save it to the Files app first, then in SideStore's **My Apps** tap **＋** and pick it from Files. Don't install by pasting the IPA's download link; some SideStore versions then fail with a Bundle ID mismatch.

## First launch

- Allow the camera and Photos: the camera to shoot; Photos to save prints and to develop photos from your library. With “Limited” access you can change it any time under Settings › Photo Access in the app.
- The first launch prepares the engine's resources for a few seconds; no internet needed.
- The shutter button at the bottom opens the camera and the button at the top right the light table; tap a photo to view it and “Edit” to open the darkroom.
- The app follows your iPhone's language (Chinese or English); to change it for this app only, go to Settings › Spektra Cam › Language.

## Updating Spektra Cam

- **With the source**: when **My Apps** in SideStore shows an Update, connect Wi-Fi and LocalDevVPN and tap it.
- **With an IPA**: download the new IPA and install it over the old one with SideStore.

Don't delete the old app first: deleting it erases the photos, recipes and settings in its library.

## Refreshing SideStore

Apps signed with a free Apple Account expire after seven days. As long as SideStore itself hasn't expired, renew on the iPhone, no computer needed:

1. Connect to Wi-Fi and turn on LocalDevVPN.
2. Open SideStore and go to **My Apps**.
3. Tap **Refresh All**, or the days left next to each app.
4. Wait until SideStore and Spektra Cam have both refreshed.

Refreshing only extends the signature; it never deletes Spektra Cam's photos or recipes. If SideStore itself has expired it can't open or renew itself: connect to the computer, reinstall SideStore over itself with iLoader, then refresh the apps on the phone.

The seven-day limit and the limits on apps and App IDs are Apple's rules for free accounts, not Spektra Cam's.

## Troubleshooting

- **SideStore says there's no Wi-Fi or LocalDevVPN**: make sure both are connected, turn off other DNS, proxy or VPN tools, then restart LocalDevVPN and SideStore.
- **A SideStore install hangs**: reopen SideStore, clear its cache, switch the Anisette server or restart the iPhone; if it still fails, re-place the pairing file with iLoader or reinstall SideStore.
- **Not enough App IDs**: a free account can register at most 10 App IDs in seven days, and Spektra Cam needs 2. Wait for old ones to expire, or check SideStore's App IDs page.
- **SideStore's pairing file stopped working**: an iOS update or a restore can invalidate it. Connect to the computer, remove the old pairing in iLoader, trust again, and put the new pairing file into SideStore.
- **The app keeps saying “The engine is still getting ready”**: the install is incomplete. Reinstall from the source or Releases (this clears the library — export what you want to keep first).
- **Exports are smaller than the original**: when full-size developing doesn't fit in memory the export is scaled down; with the film edge on, the most is about 31 MP. The export page shows the real size.

## Building from source

Needs an Apple silicon Mac, Xcode 27.2+, the iOS 27 SDK and Python 3.10+.

```bash
git clone https://github.com/HLyu3/SpektraCam.git
cd SpektraCam

# Engine: upstream 2.4.1
GITHUB_TOKEN="<your GitHub token>" python3 tools/fetch-engine.py \
  JamesQiu2005/SpektraLab f61769b6779632497cb9c457945326c8de45436e .
# 2.4.x dropped the film cover images: take engine/resources_product/film_covers from the previous engine
GITHUB_TOKEN="<your GitHub token>" python3 tools/fetch-engine.py \
  JamesQiu2005/SpektraLab 02d82b56cf65f0f8e802a708612edc4e9a4790af /tmp/engine-1.3.5
cp -R /tmp/engine-1.3.5/engine/resources_product/film_covers engine/resources_product/
python3 tools/apply-ios-patch.py engine      # run once, on a freshly fetched engine only

bash engine/setup-libraw.sh                  # LibRaw 0.22.2
ios/Tools/build-engine.sh bundle device      # must run before generating the project

SPEKTRAFILM_BUNDLE_ID=<your bundle id> SPEKTRAFILM_SIGNING_STYLE=Automatic \
SPEKTRAFILM_SIGN_IDENTITY="Apple Development" SPEKTRAFILM_TEAM_ID=<your Team ID> \
  python3 ios/Tools/gen-project.py
open ios/SpektraLab.xcodeproj
```

Run `ios/Tools/build-engine.sh bundle device` before `gen-project.py`, or the project lacks `engine-assets.bin` and the app shows “The engine is still getting ready” forever.

For “launch from the Camera Control” (press the Camera Control on the Lock Screen → unlock → the camera page), add `SPEKTRAFILM_CAMERA_CONTROL=1` when generating the project; it builds two more extensions and can only be installed with Xcode's own signing.

A free account can use `com.apple.developer.kernel.increased-memory-limit` (already in the entitlements); 48 MP full-size exports need it.

## Privacy and license

Photos, recipes, thumbnails and the develop cache stay on the iPhone. Spektra Cam collects no usage data and uploads nothing; only when an original lives in iCloud does the system Photos app download it. See and clear the develop cache under Settings › Develop.

Spektra Cam stands on these open-source projects:

Spektra Cam stands on these open-source projects:

| Project | Used for | License |
|---|---|---|
| [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) (JamesQiu2005) | The film-developing engine (C++ / Metal), black-and-white film and Multigrade paper profiles, parts of the light table and HDR code | GPL-3.0-or-later |
| [spektrafilm](https://github.com/andreavolpato/spektrafilm) (Andrea Volpato) | The film process model the SpektraLab engine follows; 28 measured film and paper profiles, enlarger LUTs | Model GPL-3.0-or-later; profiles and LUTs CC BY-SA 4.0 |
| [SpektraLab-iOS](https://github.com/Minerchu/SpektraLab-iOS) (Minerchu) | Starting point: the iOS community port 1.2.0 | GPL-3.0-or-later |
| [LibRaw](https://github.com/LibRaw/LibRaw) 0.22.2 | Fallback decoding for RAWs Core Image can't read | LGPL-2.1 / CDDL-1.0 |
| [metal-cpp](https://developer.apple.com/metal/cpp/) (Apple) | The engine's C++ interface to Metal | Apache-2.0 |

Spektra Cam's code is distributed under **GPL-3.0-or-later** (see `LICENSE`); the film and paper profiles under **CC BY-SA 4.0**.

## Trademarks

SpektraLab™ and its icon belong to their owners. Spektra Cam is an independent, unofficial project, not affiliated with or endorsed by SpektraLab or the spektrafilm project; it has its own name and icon and only says “based on the SpektraLab engine”. Film and paper names are their makers' trademarks, used only to say which public data a profile is based on.

## Feedback and contributing

For questions and reproducible bugs, use this repository's [GitHub Issues](../../issues) with your iPhone model, iOS version, Spektra Cam version and the steps to reproduce; leave out any photos you don't want public when attaching screenshots.
