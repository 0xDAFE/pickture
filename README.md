# pickture

## User Story
As a photographer, I want to be able to rate and cull both images and videos on-the-go. These images may be stored on local storage directly connected to the device or on a Network Attached Storage.
Edits in metadata made by "proper" desktop applications need to be reflected in this application and vice versa.
I don't need to make any image adjustments / editing with this app, the focus is on media management.

## Crucial Features
- Support for external storage location provided by Files.app on iOS / iPad OS to allow direct access to NAS storage
- Non-destructive editing: The original image files or video files are **NEVER** modified. All metadata is written into standard conform `.xmp` sidecars
- Metadata compatibility: Both reading and writing metadata supports common industry tools including Adobe Lightroom, Capture One, Adobe Bridge, and Darktable.
  - Sidecar conventions: Both Lightroom Classic and Capture One use `<basename>.xmp` (shared across RAW+raster pairs), while Darktable uses `<filename>.<ext>.xmp`. Pickture reads both conventions and writes to `<basename>.xmp` by default while updating existing `<filename>.<ext>.xmp` files.
  - Capture One workflow: Capture One reads and writes star ratings and color labels via XMP sidecars (synchronized with `photoshop:Urgency`), but does not support pick/reject flags in XMP. Users targeting Capture One should cull using Star Ratings or Color Labels.
- Tolerance for low bandwidth, high latency and unreliable network connections: Mobile media management is expected to be performed over unreliable mobile network connectivity as a main use case. The app does not assume reliable, high-bandwidth LAN connectivity.
- Responsiveness: Network activity (such as reading or writing metadata or media files) does not block the UI. Data is lazy loaded and cached where appropriate, keeping the UI responsive but with a clear indication of the current activity status for each media file.
- Keyboard support with shortcuts for ratings, with a configurable keyboard shortcut profile matching Capture One or Lightroom shortcuts
- The user can filter media by filename and EXIF data (e.g. camera model, lens, ratings)
- Local cache size can be configured by the user and the cache can be explicitly cleared
- The app supports a "subfolder" mode where it displays all images of a folder tree (recursively through all subfolders)
- Conflicting edits to XMP metadata can be resolved within the app, showing the user a "diff" between the two different metadata information

## UX
- The app supports common standard rating metadata, such as colors, star rating, "picked" and "rejected"
- Media pairs (e.g. the same photo as RAW + JPG) are treated as a "pair". The user can chose whether to view the preview embedded in the RAW file or the JPG.
- For easy on-the-go culling from a mobile app, a "swipe mode" allows users to easily rate images by swiping left or right
  - The performed metadata action is configurable by the user to suit different workflows and tools
  - Swipe mode can be toggled in the filmstrip view
- The UI follows adaptive layouts best suiting the UX for each platform

## UI
- The UI follows Apple's latest design patterns
- The app has two main views:
  - Grid view with an overview of the images in thumbnail format
  - Filmstrip view with one main picture and other pictures in a filmstrip at the bottom or right side of the screen (configurable)
    - On touch devices, touching in the left or right border area of the screen allows the user to navigate to the previous / next image

## Platforms
- This app supports iOS, iPad OS and MacOS

## Compatibility
- This app supports iOS / iPad OS 17 and MacOS 15. When specific features require a platform version, the app should gracefully handle this and still allow usage of the app without those fucntionalities on unsupported versions.
