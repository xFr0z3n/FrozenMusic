<p align="center">
  <img src="Resources/frozenmusic.png" width="200" alt="FrozenMusic" />
</p>

<h1 align="center">FrozenMusic</h1>

<p align="center">
  <b>Download full playlists and albums from YouTube Music and play them offline, in a player that looks and feels like YouTube Music itself.</b>
</p>

<p align="center">
  <a href="https://fr0z3n.com">Website</a> ·
  <a href="https://github.com/xFr0z3n/YTMusicUltimate/actions">Build</a> ·
  <a href="#credits">Credits</a>
</p>

---

## Features

### Downloads
- **Full playlists and albums** in one tap: one folder per playlist, track numbers follow the playlist order, songs that are already downloaded are skipped, and the numbering is updated when the playlist order changes
- **Single songs** as `.m4a` (original quality, no re-encoding) or `.mp3` (LAME)
- **Complete tags**: title, artist, album, album artist, track number, embedded cover art, plus `cover.png`, creator and description for every playlist

### Offline player
- Mini player and full player with the cover's color hue
- Queue with reordering, Play next, Add to queue, shuffle and repeat
- Lock screen and Control Center controls that never interfere with YouTube Music's own player

### Downloads tab
- Built to match YouTube Music: Library-style chips for Playlists, Songs, Albums, Artists and Creators
- Artist and creator pages, search, listening history and editable playlist order
- YouTube Music-style menus: Go to album, Go to artist, Share, Open folder and more

### Extras
- **Volume Boost** up to 2000% (swipe on the middle of the right edge, or shake)
- **Discord Rich Presence**
- Everything from YTMusicUltimate: background playback, no ads, premium features, OLED Dark Theme and more

### FrozenMusic settings
Found under **YTMusicUltimate → FrozenMusic**:

| Option | Default | What it does |
|---|---|---|
| Original YTM album look | Off | Album pages show track numbers instead of cover art |
| Player hue with OLED | Off | Keeps the cover hue in the full player with OLED Dark Theme |
| YTM volume boost look | Off | Volume Boost panel in YouTube Music's style: grey, or black with OLED Dark Theme, with a white slider |

## Installation

FrozenMusic is built as a sideloadable IPA with GitHub Actions.

1. Fork this repository.
2. In your fork, open **Settings → Actions → General** and enable **Read and write permissions**.
3. Open the **Actions** tab, select **Build and Release YTMusicUltimate** and click **Run workflow**.
4. Paste a direct link to a **decrypted** YouTube Music `.ipa` (it can't be provided here for legal reasons) and start the build.
5. When the build finishes, download the IPA from the **Releases** page of your fork (`github.com/<your-username>/YTMusicUltimate/releases`) and sideload it.

**Troubleshooting:** almost every failed build comes from the IPA link. It has to be a direct download of a decrypted `.ipa` file.

### Building locally

With [Theos](https://theos.dev/docs/installation) installed:

```sh
make clean package SIDELOADING=1   # for injecting into an IPA
make clean package ROOTLESS=1      # rootless jailbreak
make clean package                 # rootful jailbreak
```

## Overview

| # | Part |
|---|---|
| 1 | **YTMusicUltimate by dayanch96** (base of FrozenMusic, all original features, hooks, settings and the Downloads tab structure, plus the original single-song download logic: HLS stream → ffmpeg without re-encoding) |
| 2 | **youtube_music_playlist_downloader, ColoradoCrusade fork** (logic template for the playlist downloader: folder per playlist, track number = playlist position, album = playlist name, skip existing songs, renumber on reorder, embedded cover, plus album artist = playlist name, which the script didn't write) |
| 3 | **yt-dlp** (reference for YouTube's InnerTube clients and stream formats while testing a direct-download route, which YouTube blocks, so none of it ships) |
| 4 | **MaxMusic** (analyzed only: its build is a closed prebuilt `.deb`, it was unpacked to find why downloads crashed, the lookup of the player data broke in newer YouTube Music versions, the fix was rewritten independently, no code taken) |
| 5 | **mobile-ffmpeg + MBProgressHUD** (already bundled in YTMusicUltimate, used for downloading and tagging and for the progress popups) |
| 6 | **LAME 3.100** (MP3 encoder, compiled from the official source in the GitHub Actions build, LGPL license) |
| 7 | **VolumeBoostYT by irum0320, via the candyzp fork** (volume boost tweak, candyzp replaced the original touch handling that broke the seek slider with a proper gesture recognizer and a volume panel, the FrozenMusic fork adds: tap the upper part of the panel to reset to 100%, touches on seek bars are ignored so the slider always works, and it also loads in YouTube Music) |
| 8 | **Written for FrozenMusic** (capture mode for playlists and albums, m4a cover insertion, ID3v2.3 writer for mp3, title matching and stall watchdog, the offline player, the YouTube Music-style Downloads tab, and Discord Rich Presence) |

## Credits

### Based on
- **[YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate)** by dayanch96, the base of this fork: all original features and hooks, the settings, the Downloads tab structure, and the original single-song download logic (HLS manifest → audio stream → ffmpeg without re-encoding).

### Inspiration & logic reference
- **[youtube_music_playlist_downloader](https://github.com/ColoradoCrusade/youtube_music_playlist_downloader)** (ColoradoCrusade fork), the reference for the playlist downloader's logic: one folder per playlist, track number = playlist position, album = playlist name, skipping songs that are already downloaded, renumbering when the playlist order changes, and embedded covers. FrozenMusic additionally writes the playlist name as album artist.
- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)**, reference for YouTube's InnerTube clients and stream formats during development.

### Volume boost
- **[VolumeBoostYT](https://github.com/irum0320/VolumeBoostYT)** by irum0320, the original volume boost tweak.
- **[VolumeBoostYT](https://github.com/candyzp/VolumeBoostYT)** (candyzp fork), which reworked the gesture handling so it no longer breaks the seek slider, and added the volume panel.
- **[VolumeBoostYT](https://github.com/xFr0z3n/VolumeBoostYT)** (FrozenMusic fork): tap the upper part of the volume panel to reset to 100%, touches on seek bars are ignored so the slider always works, and it also loads in YouTube Music. Bundled in FrozenMusic with an optional YouTube Music look.

### Third-party components
- **[mobile-ffmpeg](https://github.com/tanersener/mobile-ffmpeg)** (bundled by YTMusicUltimate): downloads audio and writes m4a tags.
- **[MBProgressHUD](https://github.com/jdg/MBProgressHUD)** (bundled by YTMusicUltimate): progress and status popups.
- **[LAME](https://lame.sourceforge.io/)** 3.100: MP3 encoder, built from the [official source](https://sourceforge.net/projects/lame/files/lame/3.100/) during the GitHub Actions build. LAME is licensed under the [GNU LGPL](https://www.gnu.org/licenses/old-licenses/lgpl-2.0.html); its source code is available at the links above.

### Research references (no code used)
- **[MaxMusic](https://github.com/Mark02-2012/MaxMusic)**, whose prebuilt build was analyzed to understand why the original download crashed. The fix in FrozenMusic is an independent implementation.

### Written for FrozenMusic
- Playlist & album download via capture mode (the app's own player loads each song, the stream is captured and the player skips ahead)
- `.m4a` (original quality) and `.mp3` (LAME) export with full tags, embedded covers, `cover.png`, creator and description
- Custom ID3v2.3 writer and m4a cover embedding
- YouTube Music-style Downloads tab with its own offline player (queue, shuffle, repeat, lock screen controls)
- Discord Rich Presence

---

<p align="center"><sub>FrozenMusic by <a href="https://fr0z3n.com">Fr0z3n</a>. Not affiliated with Google or YouTube. YouTube Music is a trademark of Google LLC.</sub></p>
