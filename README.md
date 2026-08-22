# WebDAV Inbox for KOReader

A KOReader plugin that automatically downloads new EPUB books from a WebDAV folder to your
e-reader. It turns a WebDAV directory into a simple, self-hosted **send-to-KOReader inbox** without
requiring a separate service, vendor account, or manually entered duplicate credentials.

## What it is useful for

- Drop EPUBs into Nextcloud, ownCloud, a NAS, or another WebDAV service and pick them up in
  KOReader the next time the device connects.
- Keep the same cloud-organized book folders available on one or more KOReader devices.
- Remove a synced book from one device without having it immediately downloaded again.
- Optionally delete a book from both the device and the WebDAV source from inside KOReader.
- See and cancel background activity on slower e-ink devices.

This is deliberately a **one-way inbox**, not a general-purpose two-way file synchronizer. It
downloads missing EPUBs and never overwrites an existing local book.

This plugin maps one WebDAV folder to one local KOReader folder. It uses an account already
configured in KOReader's built-in Cloud Storage plugin, so the server address and credentials do
not need to be entered again. Whenever KOReader receives a `NetworkConnected` event, it checks the
selected WebDAV folder for EPUB files whose corresponding local filename is absent.

- New names are downloaded silently through a temporary file and atomically renamed.
- WebDAV subfolders are recreated under the selected local folder.
- Existing names at the corresponding local path are always ignored. The plugin never overwrites
  or creates a duplicate of a local book.
- Long-press an EPUB inside the configured local tree and choose **Delete synced book…** to remove
  it only from this device or from both this device and WebDAV.
- **Activity and download status** shows the current scan/download, item counts, the current path,
  and the latest 200 activity entries with the newest entry first. It can be refreshed while
  automatic downloads continue and includes a cancel button.
- The plugin interface and activity explanations support English, Simplified Chinese (`zh_CN`),
  and Traditional Chinese (`zh_TW`), following KOReader's selected interface language.

## Install

### Install with Git

From KOReader's installation directory:

```sh
git clone https://github.com/rubyxs/koreader-webdav-inbox.git plugins/webdavsend.koplugin
```

### Install manually

Download this repository and rename the extracted folder to `webdavsend.koplugin`. Copy it into
KOReader's `plugins` directory.

Restart KOReader, then configure a WebDAV account in KOReader's built-in **Cloud storage** plugin.
Open **Tools → WebDAV inbox**, choose the existing WebDAV account and remote folder, and choose a
local folder.
If it is disabled, enable it under **Tools → More tools → Plugin management → User plugins** and
restart once more.

The chosen account details are copied to this plugin's settings so unattended sync does not depend
on the Cloud Storage screen being open. Credentials are stored in KOReader's settings directory in
the same manner as the built-in Cloud Storage plugin. Use HTTPS.

## Requirements

- A recent KOReader installation with the built-in **Cloud storage** plugin enabled.
- A WebDAV account already configured in KOReader.
- Network access while KOReader is open; the plugin cannot wake a sleeping or closed device.
- EPUB files. Other document formats are currently ignored.

## Current scope

Automatic sync runs while KOReader is open and reacts to KOReader's network-connected event. It
cannot wake a sleeping or closed device. A manual **Sync now** action is also available. Recursive
scans make one WebDAV listing request per folder. The default safeguards are 250 folders and 5,000
EPUBs per scan; both can be changed under **Tools → WebDAV inbox → Scan limits**. A scan stops
without downloading when either configured limit is exceeded, protecting against runaway server
trees. Raising a limit increases listing traffic and memory use.

## Automatic scan modes

The default, reliable mode performs the complete recursive scan on every automatic sync trigger.

The optional **Low-traffic automatic sync (best effort)** mode first makes one `Depth: 0`
`PROPFIND` request for the selected collection. It uses a WebDAV sync token when available,
otherwise its ETag and/or modification timestamp. If that marker matches the last successful full
scan, recursion is skipped. The first run always performs a full scan, as does every manual
**Sync now** action.

This optimization is not a guarantee: some WebDAV providers do not change a parent collection's
marker when descendants or nested subfolders change. If a provider returns no usable marker, the
plugin automatically falls back to a full recursive scan. A failed scan or download does not save
the new marker, so the next automatic trigger retries. Changing the WebDAV source or local folder,
or allowing an ignored book to download again, invalidates the saved marker.

Because an unchanged marker skips local filename checks too, a book removed with KOReader's
ordinary **Delete** action is not restored until the marker changes or **Sync now** is used. Use
**Delete synced book… → This device only** when the book should remain absent.

Successful downloads, skipped existing names, and failures are appended to
`settings/webdavsend.log`. The log rotates to `webdavsend.log.old` after approximately 512 KiB.
Failures and successful downloads are also written to KOReader's normal diagnostic log.

The live activity view also records every automatic trigger, why a trigger could not start, when
the low-traffic check ends a run early, and how many missing EPUBs a full scan found before
downloading. Refreshing the view shows the newest entries first.

Activity codes: `AUTO` means automatic sync triggered, `AUTO_SKIP` explains why it did not start,
`START` means a sync began, `FOUND` reports missing EPUBs, `GET` means a download began, `OK` means it completed,
`SKIP` means the corresponding local filename already exists, `NO_CHANGE` means the low-traffic
check skipped recursion, `MARKER_FALLBACK` means no usable quick marker was available and a full
scan ran, `LOCAL_DELETE` means a local-only removal, `CLOUD_DELETE` means removal from both
locations, `RESTORE` means downloading was allowed again, `FAIL` means an operation failed, `DONE`
means the sync ended, and `CANCEL` means it was cancelled. `CONFLICT` can appear only in log history
written by older plugin versions.

## Sync-aware deletion

**This device only** records the remote path in a per-device ignored-books list before using
KOReader's normal local deletion operation. Future scans still list the remote file but do not
download it. If local deletion fails, the ignore entry is rolled back.

**Device and WebDAV** requires a network connection and an additional confirmation. The plugin
deletes the WebDAV copy first and removes the local copy only after the server reports success.
WebDAV `404` is accepted because the remote copy is already absent. The action is unavailable while
a sync or another deletion is running.

Use **Tools → WebDAV inbox → Ignored cloud books** to review locally removed books. Select an entry
and choose **Allow download** to make it eligible for the next sync. Selecting a different WebDAV
account or source folder clears the old source's ignore list.

Deletion adds `LOCAL_DELETE`, `CLOUD_DELETE`, and `RESTORE` records to the activity log. The local
file's KOReader metadata and history receive the same cleanup as KOReader's standard Delete action.

## Data and security

The plugin makes WebDAV requests directly from the device. It does not send account details,
filenames, or reading data to any third-party service. The selected WebDAV credentials are copied
from KOReader's Cloud storage configuration into KOReader's local settings so unattended sync can
run. Use an HTTPS WebDAV endpoint and, where supported, an app-specific password.

## License

[GNU Affero General Public License v3.0](COPYING), matching KOReader's license.
