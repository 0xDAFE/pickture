# Session-Cached Directory Listings and Explicit Refresh Over Remote Storage

Because network file shares (SMB/NFS) do not reliably broadcast filesystem change events (`FSEvents`) and continuous background polling produces server lock contention, network chatter, and keeps remote NAS disk arrays spun up, Pickture caches directory listings in memory for the active session. Directory structure and file lists are updated only when a folder is opened, when navigating subfolders, or when the user triggers an explicit refresh action (pull-to-refresh or keyboard shortcut).
