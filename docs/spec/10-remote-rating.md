# 10 — Rate on Phone (mac app addition)

The Mac app serves a small web page over Tailscale. A phone in the same tailnet opens it,
picks a recent folder and rates its files. No phone app.

```
phone (Safari) ──tailnet──▶ http://<Mac's 100.x address>:8765 ──▶ RemoteRating ──▶ Library write queue ──▶ .xmp
```

## Mac side

- **Settings (⌘,) → Rate on Phone**: a switch, the address with a copy button and a QR code.
  **File → Rate on Phone…** opens the same window. The switch is remembered (`remoteRating` in
  the user defaults) and the server starts at launch when on.
- Keys typed while Settings is the key window stay there; only the main window rates and moves.
- The server listens on the Mac's Tailscale IPv4 only (100.64.0.0/10 on a `utun` interface), so
  devices outside the tailnet cannot reach it. Without Tailscale the panel says so.
- While it runs the Mac does not idle-sleep.

## What the phone sees

- The open folder, the recent folders (spec 07 §4), then every other folder this app has
  opened, newest first. Folders that are gone or on an unmounted drive are left out.
  "Open on Mac" marks the folder in the window; file and rating counts come from the folder
  summary.
- A folder: a grid of 400 px thumbnails, RAW / JPG / MOV / All chips (RAW first, as on the Mac)
  and a rating filter (All, Unrated, 1★+ … 5★, Rejected).
- Tapping a tile opens a full-screen viewer with 2048 px previews. Swipe or tap the left or right third to move, tap ✕ or a
  star to rate. A rating advances to the next file; tapping the current rating clears it.
- Ratings made on the Mac show up when the page comes back to the foreground.

## Ratings

- A file of the folder open in the window is rated through `Library`, so the window updates at
  once. The window does not move.
- Any other folder is scanned on request. Its sidecars are written through the same write
  queue, and its dashboard summary is saved a second after the last rating.
- The phone can only name files from the last list it loaded for that folder (ids are paths
  relative to the folder).

## HTTP

| Route | Answer |
|---|---|
| `GET /` | The page (`Resources/remote.html`) |
| `GET /api/folders` | `[{id, name, open, total, rated}]` |
| `GET /api/files?folder=` | `{name, open, files: [{id, name, kind, rating, date}]}` |
| `GET /api/thumb?folder=&file=` | 400 px JPEG, through the disk thumbnail cache |
| `GET /api/preview?folder=&file=` | 2048 px JPEG |
| `POST /api/rate` `{folder, file, rating}` | `{rating}` |
