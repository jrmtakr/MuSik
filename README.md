# Music Player (Ad-Free Offline Remake)

A 100% ad-free, zero-tracking native SwiftUI iOS offline media player, folder file manager, Wi-Fi transfer server, and built-in ad-blocking browser (`iOS 17.0+`).

## Features

- **Folders & Local File Manager**: Browse, create, rename, and delete folders inside the app's `Documents` directory; move files between folders; filter by `All`, `Songs`, `Videos`, `Files`, `Favorites`, or `Recents`; sort by `Newest`, `Name`, `Largest`, or `Duration`; multi-select batch move, add-to-playlist, and delete; Quick Look previews for PDFs, images, text, and archives.
- **Audio & Video Playback**:
  - Background audio playback, Lock Screen / Control Center metadata (`MPNowPlayingInfoCenter`), and AirPlay / Picture-in-Picture (`AVPlayerViewController`).
  - **Up Next Queue** (`Add to Next Play`, `Add to Up Next`, reorder/clear queue), **Favorites**, **Recents**, **Repeat Modes** (`Pause After All`, `Loop All`, `Single Loop`), Shuffle, playback speed (`0.5x`–`2.0x`), **Sleep Timer**, and a **5-Band Audio Equalizer** with presets.
  - Edit track Title, Artist, and custom Cover Art from Photos.
  - Convert videos/audio to `.mp4` with live progress.
- **Playlists & Siri Shortcuts**: Create, reorder, and play playlists with a **Quick Access: Last Playlist** shortcut and Siri / Shortcuts support (`PlayPlaylistIntent`).
- **Wi-Fi Transfer**: Local HTTP server on port `8080` (`WiFiTransferServer`) for drag-and-drop browser uploads and downloads over Wi-Fi.
- **Ad-Free In-App Browser**:
  - Built-in WebKit `WKContentRuleList` ad & popup blocker (`ContentBlockerManager`), multi-tab & Private browsing (`WKWebsiteDataStore.nonPersistent()`), Bookmarks & History, Search Engine selector, and **Web Page Dark Mode**.
  - Automatic media detection (`fetch`, `XMLHttpRequest`, `<video>`, `<audio>`, `.m3u8` HLS streams) with **Ask Before Caching**, duration limit filtering, and **Select Video Quality** (`AVAssetDownloadURLSession` offline `.movpkg` downloads).
- **Appearance**: System, Light, or Dark theme toggle in **Settings**.

## Building an `.ipa` (for Sideloadly / AltStore / SideStore)

Push to GitHub (`main` or `master` branch) and run the **Build MusicPlayer IPA** workflow in **Actions**, then download the `MusicPlayer-ipa` artifact and unzip `MusicPlayer.ipa`.
