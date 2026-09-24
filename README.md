# FrozenMusic
<p align="center">
<img src="Resources/frozenmusic.png" width="220" alt="FrozenMusic" />
</p>

<p align="center">
YouTube Music on iOS, with a full offline Downloads experience that looks and feels like YTM itself.
</p>

<p align="center">
<a href="https://fr0z3n.com">fr0z3n.com</a> · <a href="https://github.com/xFr0z3n/YTMusicUltimate">GitHub</a>
</p>

## What's inside

FrozenMusic is built on top of YTMusicUltimate and adds:

* **Downloads tab** – playlists, songs, albums, artists and creators with Library-style chips, search, history and editable order
* **Offline player** – mini player, full player with queue, hue from the cover, lock-screen controls
* **Downloads** – songs as .mp3 / .m4a with full metadata and cover art, whole playlists and albums
* **YTM-style menus** – Play next, Add to queue, Go to album / artist, Share and more
* **FrozenMusic settings** (in the YTMusicUltimate settings):
  * Original YTM album look – track numbers instead of covers on album pages (off by default)
  * Player hue with OLED – keep the cover hue in the full player with the OLED theme (off by default)

Everything from YTMusicUltimate (background play, no ads, premium features, OLED theme, ...) is still there.

## How to build a FrozenMusic IPA using GitHub Actions

If this is your first time here, start from step 1. If you built one before, click "Sync fork" to get the latest version and continue with step 3.

1. Fork this repository using the fork button on the top right.
2. On your fork, go to Settings > Actions and enable Read and Write permissions.
3. Go to the Actions tab, click "Build and Release YTMusicUltimate" on the left and then "Run workflow" on the right.
4. Find a decrypted YouTube Music .ipa (we can't provide one for legal reasons), upload it to a file host (filebin.net, Dropbox, ...), paste the direct link and click "Run workflow".
5. When the build is done, grab the IPA from the releases of your fork (github.com/YOURUSERNAME/YTMusicUltimate/releases).

## Troubleshooting

Almost always the problem is the IPA URL. It has to be a direct link to a **decrypted .ipa** file. If the action succeeds but you can't find the result, add /releases to the URL of your fork.

## Building the package on your own machine

1. Install __[Theos](https://theos.dev/docs/installation)__
2. Clone this repo
3. In the folder run:

   • `make clean package` for rootful devices

   • `make clean package ROOTLESS=1` for rootless devices

   • `make clean package SIDELOADING=1` for injecting into an IPA (see __[Azule](https://github.com/Al4ise/Azule)__)

## Credits

FrozenMusic by Fr0z3n.

Based on __[YTMusicUltimate](https://github.com/ginsudev/YTMusicUltimate)__, made with ❤ by Ginsu and Dayanch96.
