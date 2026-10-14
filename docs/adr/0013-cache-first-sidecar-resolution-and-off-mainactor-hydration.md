# Cache-First Sidecar Resolution, Multi-Tiered Network Volume Detection, and Off-MainActor Hydration

To prevent Main RunLoop starvation, UI freezes, and cellular bufferbloat when browsing photos over high-latency remote storage (such as SMB shares on iPadOS over 4G), Pickture enforces cache-first metadata resolution, multi-tiered volume classification, and off-`@MainActor` sidecar hydration.

`StorageVolumeDetector` avoids brittle private sandbox path heuristics (such as hardcoded `LiveFiles` paths) and instead implements a three-tiered inspection strategy grounded in Apple's supported system contracts:
1. **Foundation Resource Values**: Inspects `volumeIsLocalKey == false`, `volumeURLForRemountingKey != nil`, and `volumeTypeNameKey` (detecting `"smbfs"`, `"nfs"`, `"webdav"`, and `"afpfs"`), immediately classifying network volumes as `NetworkShare`.
2. **Darwin / POSIX VFS Introspection**: Queries BSD `statfs` to verify whether the `MNT_LOCAL` flag is cleared (`(f_flags & MNT_LOCAL) == 0`) and validates `f_fstypename`.
3. **Hardware Fallback**: Evaluates `volumeIsInternalKey` and `volumeIsLocalKey` to distinguish `InternalSSD` from `RemovableMedia`.

`SidecarCodec` enforces cache-first resolution by querying `DirectoryListingCache.shared` strictly before executing any filesystem `fileExists` calls. Missing sidecars are resolved entirely in-memory with zero disk/network roundtrips. During folder initialization in `MetadataSyncEngine`, items confirmed to have no `.xmp` on disk in `DirectoryListingCache` are immediately initialized to `SyncState.synced` with an empty snapshot in-memory, bypassing background tasks and loading spinners entirely.

For items possessing an on-disk `.xmp` sidecar, `MetadataHydration` is decoupled from `@MainActor`: file reads, XMP parsing, SHA-256 digest calculation, and SQLite `BaseSnapshot` recording in `MetadataSyncStore` execute on cooperative background tasks off `@MainActor`. On-demand cell hydration requests are throttled through a bounded LIFO queue (max 2 workers on `NetworkShare`) that cancels off-screen tasks during rapid flinging, while mass background updates are batched with a 300ms debounce to prevent `@Observable CullingSession` invalidation churn.
