# rPlayHub Share — the companion app

A tiny Android app that adds **Send to Mac** to the system Share sheet. Share a photo (or any
file) from an app running in a rPlayHub fusion window, and it appears on the Mac — as a draggable
thumbnail on the fusion window, or in Finder — ready to drag anywhere.

## How it works

It needs **no runtime permissions and no Shizuku**. The share target copies each shared item into
its own external files directory (`/sdcard/Android/data/ai.rplay.rplayhub.share/files/outbox/`),
writing a `.ready` marker last. The Mac app's `ShareInbox` polls that directory over adb while a
session is live — the adb shell can read it (shell is in the `ext_data_rw` group) — pulls each
ready batch to `~/Downloads/rPlayHub Shared/`, deletes it on the device, and presents it.

Why share-to-send and not a literal cross-window drag: Android delivers a dragged item's content
URI only on **drop**, never as the drag begins, so a drag that starts inside the mirrored app
can't hand its file to the Mac. Sharing is the supported path; the draggable thumbnail on the
fusion window makes it feel like dragging the photo straight out.

## Build & install

    ./tools/build-helper.sh
    adb install -r helper/app/build/outputs/apk/debug/app-debug.apk

Then, on the phone, open an app (e.g. Google Photos in a fusion window), pick a photo, tap
**Share ▸ Send to Mac**.
