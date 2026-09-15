# WebDAV Inbox for KOReader

A KOReader plugin that automatically downloads new EPUB books from **one or more WebDAV folders**
to your e-reader. Each WebDAV source is configured as an independent mapping to a local KOReader
folder.

## Multiple WebDAV mappings

Open **Tools → WebDAV inbox → WebDAV mappings** to add, edit, enable/disable, or remove mappings.
Each mapping keeps its own:

- WebDAV server, credentials, and remote folder
- local destination folder
- seen-file state
- locally ignored books
- low-traffic collection marker

An existing single-source configuration from v1.0 is migrated automatically to the first mapping.
Downloaded books are not moved or deleted during migration.

### Sharing one local directory

Multiple WebDAV mappings may point to the same local directory. This is supported intentionally.
The plugin keeps an ownership registry for files that it downloads. If mapping A has downloaded a
local path and mapping B later exposes the same relative path, B logs `COLLISION` and skips that
file. It never overwrites the file or claims it for B.

Files that already existed locally before this version remain unowned and retain the original
behavior: they are skipped and never overwritten. When a local file cannot be unambiguously
associated with one of several mappings, the sync-aware WebDAV delete action is not offered for
that file; this prevents deletion from the wrong remote source.

Changing or removing a mapping clears only that mapping's ownership records; it never deletes its
already-downloaded local files.

## What it is useful for

- Drop EPUBs into Nextcloud, ownCloud, a NAS, or another WebDAV service and pick them up in
  KOReader the next time the device connects.
- Combine separate WebDAV accounts or folders into one local library.
- Map different WebDAV sources to different local folders.
- Keep the same cloud-organized book folders available on one or more KOReader devices.
- Remove a synced book from one device without having it immediately downloaded again.
- Optionally delete an owned book from both the device and its correct WebDAV source.
- See and cancel background activity on slower e-ink devices.

This is deliberately a **one-way inbox**, not a general-purpose two-way file synchronizer. It
downloads missing EPUBs and never overwrites an existing local book.

## Sync behavior

**Sync now** processes every enabled, fully configured mapping sequentially in one background job.
You can also open an individual mapping and use **Sync this mapping now**.

Whenever KOReader receives a network-connected event, automatic sync checks all enabled mappings.
WebDAV subfolders are recreated under each mapping's selected local folder.

The optional **Low-traffic automatic sync (best effort)** mode maintains an independent collection
marker for every mapping. A mapping whose marker has not changed may skip its recursive scan,
while other mappings continue normally. Manual sync always performs a full recursive scan.

Default safeguards are 250 folders and 5,000 EPUBs **per mapping per scan**. They can be changed
under **Tools → WebDAV inbox → Scan limits**.

## Sync-aware deletion

For files owned by a mapping, long-press an EPUB and choose **Delete synced book…**:

- **This device only** deletes the local copy and adds that remote path to that mapping's own
  ignored list.
- **Device and WebDAV** deletes from the owning WebDAV mapping first, then deletes the local file.

With overlapping/shared local roots, the plugin only exposes this action when it can identify one
mapping unambiguously.

## Activity log

`settings/webdavsend.log` records sync activity. Important codes include:

- `START`, `FOUND`, `GET`, `OK`, `SKIP`, `DONE`
- `COLLISION` — another WebDAV mapping owns the same local path, so the current mapping skipped it
- `NO_CHANGE`, `MARKER_FALLBACK`
- `LOCAL_DELETE`, `CLOUD_DELETE`, `RESTORE`
- `FAIL`, `CANCEL`, `AUTO`, `AUTO_SKIP`

## Install

Copy `webdavsend.koplugin` into KOReader's `plugins` directory and restart KOReader. Configure each
WebDAV account first in KOReader's built-in **Cloud storage** plugin, then add mappings from
**Tools → WebDAV inbox → WebDAV mappings**.

The selected account details are copied to this plugin's local settings so unattended sync does
not depend on the Cloud Storage screen being open. Use HTTPS.

## Requirements

- A recent KOReader installation with the built-in **Cloud storage** plugin enabled.
- One or more WebDAV accounts configured in KOReader.
- Network access while KOReader is open.
- EPUB files. Other document formats are currently ignored.

## Data and security

The plugin makes WebDAV requests directly from the device. It does not send account details,
filenames, or reading data to any third-party service. Credentials are stored in KOReader's local
settings in the same manner as the built-in Cloud Storage plugin. Use an HTTPS WebDAV endpoint and,
where supported, an app-specific password.

## License

[GNU Affero General Public License v3.0](COPYING), matching KOReader's license.
