# P5 Preview Monitor 0.3.0 (build 29), pre-release

A macOS app for Archiware P5 sites that make previews with `vid2mos-hardened.sh`. P5 shows one
preview counter on the server and nothing on the clients; this app shows the rest, and repairs
previews that failed. The code is not public; this repository carries its releases because the app
and the script are made to work together.

Pre-release, provided as is, with no support.

## What it does

- **Watch preview generation:** the server's preview counter, each client's vid2mos log over SSH
  (OK, failed, running, hung), one health banner, notifications, a menu bar item and an optional
  read-only web wallboard.
- **History:** a local ledger of every preview run, batch and issue, with per-machine failure
  rates, timings and reasons.
- **Fix previews:** every file whose preview failed, each at its next step:
  - **Check in P5** (reads only): the archive entry, its tapes, whether it has a preview, and
    whether the source is still on disk.
  - **Restore** from tape, into a dated folder or back to the original location.
  - **Retry** the preview on a client, with the ffmpeg builds and time limit you choose.
    **Check ffmpeg** tests the tools on that client first.
  - **Attach to P5:** the new preview becomes the archived file's preview. No metadata is
    written, and each result is confirmed by reading the entry back.

  Restore and attach change things in P5 and are off until you turn them on in Settings.

## Requirements

- macOS 14 or later (Apple silicon or Intel).
- Key-based SSH from this Mac to the P5 server and each preview client. The app never stores a
  password for SSH.
- For Check in P5, Restore and Attach: a P5 REST user, whose password is kept in the Keychain.
- `vid2mos-hardened.sh` 1.1.0 or later on the clients; 1.4.0 for the `/usr/local/bin` ffmpeg
  fallback. `prepare-client.sh` in this repository installs it and runs its self-test.

## Install

Download the DMG, open it and drag the app to Applications. Its checksum is in the `.sha256.txt`
file beside the DMG. The app is signed and notarized.
