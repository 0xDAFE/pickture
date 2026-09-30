import SwiftUI

struct SettingsSheetView: View {
    let session: CullingSession
    @Environment(\.dismiss) private var dismiss

    private var sliderMegabytesBinding: Binding<Double> {
        Binding(
            get: {
                Double(session.cacheSizeLimitBytes) / (1_024.0 * 1_024.0)
            },
            set: { newMegabytes in
                let bytes = Int64(newMegabytes * 1_024.0 * 1_024.0)
                session.setUserConfiguredCacheSizeLimitBytes(bytes)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Current Cache Usage")
                        Spacer()
                        Text("\(session.formattedCacheUsage) / \(session.formattedCacheLimit)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Cache Size Limit")
                            Spacer()
                            Text(session.formattedCacheLimit)
                                .font(.subheadline.weight(.semibold))
                        }

                        Slider(
                            value: sliderMegabytesBinding,
                            in: 250.0...(20.0 * 1_024.0),
                            step: 250.0
                        ) {
                            Text("MediaCache Quota")
                        } minimumValueLabel: {
                            Text("250 MB")
                                .font(.caption2)
                        } maximumValueLabel: {
                            Text("20 GB")
                                .font(.caption2)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(MediaCache.quotaPresetsBytes, id: \.bytes) { preset in
                                    Button(preset.label) {
                                        session.setUserConfiguredCacheSizeLimitBytes(preset.bytes)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(session.cacheSizeLimitBytes == preset.bytes ? .accentColor : .secondary)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    Button(role: .destructive) {
                        session.clearMediaCache()
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                } header: {
                    Text("MediaCache (Thumbnails & Previews)")
                } footer: {
                    Text("MediaCache evicts least-recently-used thumbnails automatically when usage exceeds your configured byte quota (250 MB – 20 GB). Clearing MediaCache never deletes unsynchronized ratings or pending sidecar writes in MetadataSyncStore.")
                }

                Section {
                    Picker(
                        "Filmstrip Dock Position",
                        selection: Binding(
                            get: { session.filmstripDockPosition },
                            set: { session.setFilmstripDockPosition($0) }
                        )
                    ) {
                        ForEach(FilmstripDockPosition.allCases, id: \.self) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }

                    Toggle(
                        "Border Tap Navigation",
                        isOn: Binding(
                            get: { session.isBorderTapNavigationEnabled },
                            set: { _ in session.toggleBorderTapNavigation() }
                        )
                    )
                } header: {
                    Text("Filmstrip & Touch")
                } footer: {
                    Text("When Border Tap Navigation is enabled, tapping within the left or right outer border zones (min(width * 0.12, 64pt)) navigates to the previous or next item. Disable to prevent accidental navigation from hand/thumb grip.")
                }

                Section {
                    Picker(
                        "Shortcut Profile",
                        selection: Binding(
                            get: { session.shortcutProfileKind },
                            set: { session.setShortcutProfileKind($0) }
                        )
                    ) {
                        ForEach(ShortcutProfileKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    Toggle(
                        "Auto-Advance Selection (A)",
                        isOn: Binding(
                            get: { session.isAutoAdvanceEnabled },
                            set: { _ in session.toggleAutoAdvance() }
                        )
                    )
                } header: {
                    Text("Shortcuts & Auto-Advance")
                } footer: {
                    Text("Lightroom profile maps ratings 0–5, flags P/X/U, labels 6–9. Capture One profile maps ratings 0–5, flags +/-/U, label *. Auto-Advance automatically moves selection to the next item immediately after applying a rating, flag, or label.")
                }

                Section("Preview & Discovery Defaults") {
                    Picker(
                        "Default PreviewSource",
                        selection: Binding(
                            get: { session.previewSource },
                            set: { session.previewSource = $0 }
                        )
                    ) {
                        Text("Prefer Raster (JPEG/HEIC)").tag(PreviewSource.preferRaster)
                        Text("Prefer RAW Embedded Preview").tag(PreviewSource.preferRAW)
                    }

                    Toggle(
                        "Recursive SubfolderMode",
                        isOn: Binding(
                            get: { session.subfolderMode == .recursive },
                            set: { isRecursive in
                                try? session.setSubfolderMode(isRecursive ? .recursive : .immediate)
                            }
                        )
                    )
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pickture Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
    }
}
