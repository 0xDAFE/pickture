# Separation of Evictable MediaCache and Durable MetadataSyncStore

Pickture allows users to cap local cache disk usage and explicitly clear cached data at any time, while also operating over unreliable network storage where `.xmp` writes may remain queued across sessions. To prevent cache eviction or a user-triggered "Clear Cache" action from destroying unsynchronized culling work, Pickture splits local storage into two independent stores:
1. **`MediaCache`** (in the system Caches directory): an LRU-evictable store of rendered thumbnails and preview images governed by the user's configured byte limit and safe to purge at any time.
2. **`MetadataSyncStore`** (in Application Support): a durable on-disk journal that persists `BaseSnapshot`s, extracted `ExifMetadata`, and `PendingWrite` mutations across app restarts, ensuring pending ratings and unresolved `MetadataConflict`s survive both cache purges and application termination.
