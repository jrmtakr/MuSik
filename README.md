# Music Player (1-to-1 Ad-Free Offline Remake)

A 100% ad-free, zero-tracking native SwiftUI iOS remake matching the core features of **Offline** (`iOS 17.0+`).

## Tabs & Features

1. **Discovery**:
   - Search bar (`Search or enter web address`) with switchable Search Engines (`Google`, `DuckDuckGo`, `Bing`, `Yahoo`, `Brave`).
   - Customizable **Websites** Speed Dial grid (`New website`, `Modify website`, `Delete`, `Save Link`).
   - Quick shelves for **Offline Songs**, **Recents**, and **Bookmarks**.
   - Integrated Ad-Free In-App Browser (`WKWebView` + `WKContentRuleList` ad/popup blocker, multi-tab + Private tabs, Bookmarks & History, **Web Page Dark Mode**, **Inline Video Player** toggle, **Download Images**, `.atDocumentStart` media detection with **Ask Before Caching** / auto-cache / duration limit, and **Select Quality** for offline `.movpkg` HLS downloads).
2. **Playlists**:
   - `Quick Access: Last Playlist`, pinned smart collections (**Liked Songs**, **Offline Songs**, **Recents**), Search & Sort, Play All / Shuffle Play, custom playlists with **Custom Cover** picker, and Siri Shortcuts (`PlayPlaylistIntent`).
3. **Files (`This iPhone`)**:
   - Hierarchical folders (`New Folder`, rename, delete, move), duplicate conflict prompt (`Overwrite` / `Keep Both`), filter chips (`All`, `Songs`, `Videos`, `Pictures`, `Documents`), full Sort (`Default`, `Date`, `Name`, `Artist`, `Duration`, `Size`, `Type`), multi-select batch actions, Photos import (videos & images), **Unzip** for `.zip`/`.cbz` archives, **Image/Comic Reader** (`Scroll` / `Page` modes), **Text/Story Reader** (font size & dark theme), Quick Look, MP4 converter, and **Wi-Fi Transfer** web file manager (browse folders, create folder, upload, download, rename, delete).
4. **Media Player**:
   - Background audio, Lock Screen controls, AirPlay, PiP, **Up Next** queue (`Add to Next Play`, `Add to Up Next`), **Liked**, 3-way repeat (`Pause After All`, `Loop All`, `Single Loop`), Shuffle, Playback Speed (`0.5x`–`2.0x`), **Sleep Timer**, **5-Band Audio Equalizer**, and editable Title/Artist/Cover Art.
5. **Setting**:
   - **Appearance** (`System`, `Light`, `Dark`), **App Icons** (`Default`, `Dark`, `Light`, `Midnight`, `Amber`), **Video Setting**, **Reading Direction**, **Language**, and **Clear History**.

## Building an `.ipa` (for Sideloadly / AltStore / SideStore)

Push to GitHub (`main` or `master` branch) and download the `MusicPlayer-ipa` artifact from the **Build MusicPlayer IPA** workflow under **Actions**.
