# Music Player (1-to-1 Ad-Free Offline Remake)

A 100% ad-free, zero-tracking native SwiftUI iOS remake matching the core features of **Offline** (`iOS 17.0+`).

## Tabs & Features

1. **Discovery**:
   - Search bar (`Search or enter web address`) with switchable Search Engines (`Google`, `DuckDuckGo`, `Bing`, `Yahoo`, `Brave`) opening directly in the persistent **Browser** tab.
   - Customizable **Websites** Speed Dial grid (`New website`, `Modify website`, `Delete`, `Save Link` with automatic HTML media link extraction).
   - Quick shelves for **Offline Songs**, **Recents**, and **Bookmarks**.
2. **Playlists**:
   - `Quick Access: Last Playlist`, pinned smart collections (**Liked Songs**, **Offline Songs**, **Recents**), Search & Sort, Play All / Shuffle Play, custom playlists with **Custom Cover** picker, and Siri Shortcuts (`PlayPlaylistIntent`).
3. **Browser**:
   - Persistent In-App Browser (`WKWebView` + `WKContentRuleList` ad/popup blocker + cosmetic/ad-skipper script, multi-tab + Private tabs, Bookmarks & History, **Web Page Dark Mode**, **Inline Video Player** toggle, **Download Images**, `fetch`/`XHR`/`PerformanceObserver`/Shadow DOM/`blob:` **Detected Streams** sniffer, native + FFmpeg HLS segment downloader & AES-128 decryptor with **Select Quality**, HTTP disk range-caching proxy (`LocalMediaCacheProxy` & `MediaInterceptURLProtocol`), cookie/Referer/Origin/User-Agent header forwarding, **Ask before caching** / **Don't Remind** / **Enable Automatic Caching** / upfront duration limit check, and `"👉 Tap to playback offline!"` banner).
4. **Files (`This iPhone`)**:
   - Hierarchical folders (`New Folder`, rename, delete, move), duplicate conflict prompt (`Overwrite` / `Keep Both`), filter chips (`All`, `Songs`, `Videos`, `Pictures`, `Documents`), full Sort (`Default`, `Date`, `Name`, `Artist`, `Duration`, `Size`, `Type`), multi-select batch actions, Photos import (videos & images), **Unzip** for `.zip`/`.cbz` archives, **Image/Comic Reader** (`Scroll` / `Page` modes), **Text/Story Reader** (font size & dark theme), Quick Look, MP4 converter/remuxer, **Extract Audio (.m4a)**, and **Wi-Fi Transfer** web file manager.
5. **Media Player (Apple AVFoundation + FFmpeg/`KSPlayer`)**:
   - Full playback for both Apple formats (`mp3`, `m4a`, `wav`, `aac`, `flac`, `aiff`, `caf`, `mp4`, `mov`, `m4v`, `movpkg`) and FFmpeg non-Apple formats (`mkv`, `avi`, `webm`, `flv`, `wmv`, `rmvb`, `ts`, `m2ts`, `vob`, `ogv`, `divx`, `3gp`, `mpg`, `mpeg`, `ogg`, `opus`, `wma`, `ape`, `ac3`, `dts`, `amr`) with automatic fallback, background audio, Lock Screen controls, AirPlay, PiP, `±30s` skip controls, **Up Next** queue, **Liked**, 3-way repeat, Shuffle, Playback Speed (`0.5x`–`2.0x`), **Sleep Timer**, **5-Band Audio Equalizer**, **Screenshot** video frame capture, **Extract Audio (.m4a)**, and editable Title/Artist/Cover Art.
6. **Setting**:
   - **Appearance** (`System`, `Light`, `Dark`), **App Icons** (`Default`, `Dark`, `Light`, `Midnight`, `Amber`), **Video Setting**, **Reading Direction**, **Language** (11 `.lproj` localizations: `en`, `es`, `fr`, `de`, `pt`, `ja`, `zh-Hans`, `ar`, `ru`, `tr`, `hi`), **Clear Stream Cache**, and **Clear History**.

## Building an `.ipa` (for Sideloadly / AltStore / SideStore)

Push to GitHub (`main` or `master` branch) and download the `MusicPlayer-ipa` artifact from the **Build MusicPlayer IPA** workflow under **Actions**.
