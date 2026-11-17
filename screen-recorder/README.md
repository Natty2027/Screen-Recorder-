# Screen Recorder

A simple, private screen recorder that runs entirely in your browser. There's nothing to install, no account, and no uploads: your recordings never leave your computer.

It's inspired by open-source recorders like [Screenity](https://github.com/alyssaxuu/screenity), [OBS Studio](https://github.com/obsproject/obs-studio) and [Cap](https://github.com/CapSoftware/Cap), and is written in plain JavaScript (one HTML file, no dependencies).

## Features

- **Record a screen, a window or a browser tab**
- **Computer audio + microphone**, mixed into one track, with a live mic level meter
- **Floating webcam bubble** that stays on top of other windows and gets recorded with your screen (Document Picture-in-Picture)
- **Quality presets:** 720p, 1080p, 1080p60 and 1440p
- **MP4 (H.264) or WebM**, depending on what your browser supports
- **3-second countdown**, plus pause, resume and a timer
- **Saves straight to a folder you pick**: video is written to disk every second, so a crash loses almost nothing. Without a folder, the file downloads when you stop.
- **Keyboard shortcuts** (while the page is focused): `Alt+R` start/stop, `Alt+P` pause/resume

## Use it

**Option 1: open locally.** Download `index.html` and open it in Chrome or Edge.

**Option 2: GitHub Pages.**
1. Push this repo to GitHub.
2. Go to **Settings → Pages**, set **Source** to "Deploy from a branch", and pick `main` / `(root)`.
3. Open `https://<your-username>.github.io/<repo-name>/`.

Then:
1. Pick your options (mic, computer audio, webcam, quality, format).
2. Optionally click **Choose…** to pick a save folder.
3. Click **Start recording** and choose what to share.
4. Click **Stop**, or use your browser's "Stop sharing" bar.

## Browser support

| Feature | Chrome / Edge | Firefox | Safari |
|---|---|---|---|
| Screen recording | ✅ | ✅ | ✅ |
| Save to a chosen folder | ✅ | ❌ (downloads instead) | ❌ (downloads instead) |
| Floating webcam bubble | ✅ | ⚠️ limited | ⚠️ limited |
| Computer audio | ✅ tab audio everywhere, full system audio on Windows | ❌ | ❌ |
| MP4 output | ✅ (Chrome 126+) | WebM | ✅ |

## How it works

- `getDisplayMedia()` captures the screen, and `getUserMedia()` captures the mic and camera.
- The Web Audio API mixes the computer and mic audio into a single track.
- `MediaRecorder` encodes the video in 1-second chunks.
- The File System Access API (`showDirectoryPicker`) writes those chunks straight into a file in your chosen folder.

## License

[MIT](LICENSE)
