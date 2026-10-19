# FrozenSC Discord RPC

A small add-on tweak that brings the FrozenMusic-style **Discord Rich Presence** to
**SoundCloud**, on top of your existing FrozenSC (NexaSC) tweak.

It shows what you're listening to on SoundCloud as your Discord status — song, artist,
progress bar and (optionally) cover art — and adds a **Discord RPC** entry to FrozenSC's
settings screen (the one you open by long-pressing in the tab bar) that works exactly like
the FrozenMusic one.

## How it works

FrozenSC's settings are a table driven by `NexaSCSettingsViewController`. This add-on:

- **Presence engine** (`Source/DiscordRPC.x`): hooks `MPNowPlayingInfoCenter` — the same
  system API FrozenMusic uses — so it reads the currently playing track independently of
  SoundCloud's internals. It talks to Discord's gateway with your account token and, when
  cover-art storage is configured, uploads each track's artwork to your WebDAV and registers
  it as an external asset. Rate-limiting, reconnection/resume and an artwork cache are all
  carried over from the proven FrozenMusic implementation.
- **Settings entry** (`Source/SettingsHook.x`): hooks `NexaSCSettingsViewController` to append
  a one-row **Discord RPC** section. Tapping it opens the configuration screen
  (`Source/Prefs/FrozenSCDiscordSettingsController.m`) — a SoundCloud-orange copy of the
  FrozenMusic Discord RPC screen.

Nothing inside the FrozenSC/NexaSC binary is modified; this loads alongside it.

## Configuration

Open SoundCloud, long-press in the tab bar to open FrozenSC's settings, and tap **Discord RPC**.
You can either:

1. **Set it up in the app** — paste your Discord **App ID** and account **Token**, and
   (optionally) your Nextcloud/WebDAV details for cover art. Values are stored on-device
   (token + password in the Keychain) and take effect after restarting SoundCloud (tap ✓).
2. **Build it in** — add these repository secrets to your fork
   (*Settings → Secrets and variables → Actions*) and build with the workflow:
   `DISCORD_APP_ID`, `DISCORD_TOKEN`, `NEXTCLOUD_WEBDAV_URL`, `NEXTCLOUD_USER`,
   `NEXTCLOUD_PASS`, `NEXTCLOUD_PUBLIC_URL`. Anything set in the app overrides the matching
   secret.

> Your Discord account token logs into your account — keep it private. Using an account token
> this way is not officially supported by Discord; use it at your own risk.

## Building

The workflow `.github/workflows/frozensc.yml` (at the repo root) builds the add-on and injects
it, **together with your existing FrozenSC dylib**, into a decrypted SoundCloud IPA.

Run it from the Actions tab with:

- `ipa_url` — URL to a decrypted SoundCloud IPA
- `frozensc_dylib_url` — URL to your existing FrozenSC (NexaSC) `.dylib`

It produces a draft release with the patched `SoundCloud.ipa`.

To build just the add-on `.deb` locally with [Theos](https://theos.dev):

```sh
cd FrozenSC
make clean package DEBUG=0 FINALPACKAGE=1 SIDELOADING=1
```

Then inject it next to your FrozenSC dylib with your usual tool, e.g.:

```sh
cyan -i SoundCloud.ipa -o SoundCloud-patched.ipa -uwsf NexaSC.dylib packages/*.deb
```
