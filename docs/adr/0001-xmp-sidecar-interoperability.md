# Dual-Convention XMP Sidecar Discovery and Interoperable Rating Schema

Pickture must exchange non-destructive metadata with Capture One, Adobe Lightroom, Adobe Bridge, and open-source RAW editors without ever modifying original image or video files. Both Adobe Lightroom Classic and Capture One use `<basename>.xmp` by default (shared across RAW+raster pairs), whereas Darktable produces `<filename>.<ext>.xmp`. Pickture reads both conventions (preferring `<basename>.xmp` when both exist) and writes to `<basename>.xmp` by default while also updating `<filename>.<ext>.xmp` if one already exists on disk.

For metadata encoding:
- `PickFlag` is stored in `crs:Pick` (`1`, `0`, `-1`) and `xmpDM:pick`. Because Capture One does not support pick/reject flags in XMP sidecars, Pickture maintains flag isolation without mutating ratings or color labels; users preparing files for Capture One are guided to use Star Ratings and Color Labels for culling.
- `StarRating` (`0`–`5`) is stored in `xmp:Rating` (treating an incoming `xmp:Rating="-1"` without `crs:Pick` as `Rejected` + `0` stars on read).
- `ColorLabel` is stored in `xmp:Label` and synchronized with `photoshop:Urgency` (`1` for Red, `2` for Green, `3` for Yellow, `4` for Blue, `5` for Orange, `6` for Purple; cleared on None) to guarantee reliable color label display across localized versions of Capture One.
- Round-trip writes use a lossless XML DOM that handles multiple `<rdf:Description>` blocks (such as those output by ExifTool), adapts to host document tag style (child element vs attribute), and preserves all unrelated XML namespaces, develop parameters, comments (`<!-- ... -->`), CDATA blocks, and processing instructions (`<?xpacket ... ?>`) intact.
