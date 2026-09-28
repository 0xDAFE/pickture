# Pickture

Pickture is a non-destructive mobile and desktop photography culling and rating application that operates directly on external and network-attached storage via XMP sidecar files.

## Language

### Media & Storage

**MediaItem**:
A single logical photographic or video capture presented to the user in the Grid or Filmstrip, representing either a standalone file or a matched RAW + raster pair sharing a common basename in the same folder.
_Avoid_: Asset, Photo, Entry, Record

**MediaFile**:
An individual physical image or video file on disk (such as a `.ARW` RAW file, a `.JPG` raster file, or a `.MOV` video file) that belongs to a `MediaItem`.
_Avoid_: Source, Blob, Attachment

**MediaPair**:
A `MediaItem` backed by both a RAW `MediaFile` and a raster (e.g. JPEG/HEIC) `MediaFile` in the same directory with the same case-insensitive basename, allowing the user to switch which preview representation is displayed while sharing a single set of rating metadata.
_Avoid_: Stack, Group, Bundle, Duplicate

**Sidecar**:
A standard-conformant `.xmp` file stored alongside a `MediaItem`'s `MediaFile`(s) that persists all non-destructive rating and culling metadata without modifying the original media files.
_Avoid_: Metadata file, Tag file, Companion file

**SubfolderMode**:
A browsing mode in which opening a root folder presents all `MediaItem`s recursively across its entire directory subtree rather than only the immediate folder's contents, while keeping `MediaPair` matching scoped strictly within each individual directory.
_Avoid_: Flat view, Deep scan, Recursive library

### Culling & Metadata

**CurationMetadata**:
The set of non-destructive culling attributes managed by Pickture for a `MediaItem`—specifically its `StarRating`, `PickFlag`, and `ColorLabel`—alongside read-only camera EXIF attributes used for filtering.
_Avoid_: Adjustments, Edits, Tags

**StarRating**:
An integer rating from `0` (unrated) to `5` assigned to a `MediaItem`.
_Avoid_: Score, Rank, Grade

**PickFlag**:
The ternary selection state of a `MediaItem` during culling: `Picked`, `Unflagged`, or `Rejected`.
_Avoid_: Selection, Bookmark, Favorite, Trash

**ColorLabel**:
A categorical color marker (`None`, `Red`, `Orange`, `Yellow`, `Green`, `Blue`, `Purple`, `Grey`) assigned to a `MediaItem` for workflow organization across desktop tools.
_Avoid_: Color tag, Badge, Swatch

**ExifMetadata**:
Read-only technical capture attributes of a `MediaItem` (camera model, lens model, focal length, aperture, shutter speed, ISO, and capture date) extracted from XMP sidecars and file headers for display and filtering.
_Avoid_: Technical properties, Camera info, File info

**PreviewSource**:
The active representation preference (`PreferRaster` or `PreferRAW`) that determines whether a `MediaPair` displays its paired raster image or its embedded RAW preview.
_Avoid_: Render mode, View source, Image quality

**FilterCriteria**:
A composable query over the current folder or subtree combining filename substring, `StarRating`, `PickFlag`, `ColorLabel`, `ExifMetadata` facets, media kind, and `SyncState` (using OR within a dimension and AND across dimensions).
_Avoid_: Search filter, View query, Facet state

### Interaction & Workflows

**CurationAction**:
A single or compound metadata mutation (applying one or more of `PickFlag`, `StarRating`, and `ColorLabel`) invoked via a keyboard shortcut, button, or swipe gesture.
_Avoid_: Edit command, Rating event

**ShortcutProfile**:
A named set of keyboard bindings mapping keys to `CurationAction`s and navigation commands, including built-in `Lightroom` and `CaptureOne` presets as well as a user-customized profile.
_Avoid_: Keymap, Hotkey preset

**SwipeMode**:
An on-the-go culling mode inside the Filmstrip view where left and right swipe gestures execute user-configured `CurationAction`s and automatically advance to the next `MediaItem`.
_Avoid_: Card view, Tinder mode, Quick cull

**BorderTapNavigation**:
A user-toggleable touch interaction in the Filmstrip view that maps taps in the left and right outer border zones of the main viewport to Previous / Next `MediaItem` navigation, which can be disabled to prevent accidental navigation from thumb grip.
_Avoid_: Edge swipe, Margin tap

### Synchronization & Conflicts

**SyncState**:
The current per-`MediaItem` synchronization status between Pickture's local state and the underlying storage (`Synced`, `Loading`, `PendingWrite`, `Conflicted`, or `SyncError`).
_Avoid_: Network status, Connection state

**BaseSnapshot**:
The last known synchronized `CurationMetadata` state and file digest of a `Sidecar` at the time Pickture read or last wrote it, used as the common ancestor when checking for external edits.
_Avoid_: Backup, Previous version, Original metadata

**MetadataConflict**:
A state where a `MediaItem` has unsynchronized local edits (`PendingWrite`) while its on-disk `Sidecar` has simultaneously been modified externally since the `BaseSnapshot`, requiring user resolution between local and remote values.
_Avoid_: Sync error, Collision, Merge failure

**MediaCache**:
The evictable local disk cache of rendered thumbnails and decoded preview images bounded by a user-configurable byte quota (LRU) that can be cleared at any time without affecting unsynchronized metadata.
_Avoid_: Temp folder, Image store

**MetadataSyncStore**:
The durable on-disk journal (surviving app restarts) that stores `BaseSnapshot`s, cached `ExifMetadata`, and queued `PendingWrite` mutations until they are flushed to their target `Sidecar`s or explicitly resolved.
_Avoid_: Offline cache, Temp database
