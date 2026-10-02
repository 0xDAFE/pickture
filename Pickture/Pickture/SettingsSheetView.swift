import SwiftUI

struct SettingsSheetView: View {
    @Bindable var session: CullingSession
    var showsDismissButton: Bool = true
    @Environment(\.dismiss) private var dismiss

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
                            value: $session.cacheSizeLimitMegabytes,
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
                    Picker("Filmstrip Dock Position", selection: $session.filmstripDockPosition) {
                        ForEach(FilmstripDockPosition.allCases, id: \.self) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }

                    Toggle("Border Tap Navigation", isOn: $session.isBorderTapNavigationEnabled)
                } header: {
                    Text("Filmstrip & Touch")
                } footer: {
                    Text("When Border Tap Navigation is enabled, tapping within the left or right outer border zones (min(width * 0.12, 64pt)) navigates to the previous or next item. Disable to prevent accidental navigation from hand/thumb grip.")
                }

                Section {
                    Toggle("SwipeMode Culling", isOn: $session.isSwipeModeEnabled)

                    NavigationLink {
                        SwipeActionDetailEditorView(
                            title: "Swipe Right Action",
                            direction: .right,
                            action: $session.swipeRightAction
                        )
                    } label: {
                        HStack {
                            Label("Swipe Right", systemImage: "arrow.right.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(session.swipeRightAction.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        SwipeActionDetailEditorView(
                            title: "Swipe Left Action",
                            direction: .left,
                            action: $session.swipeLeftAction
                        )
                    } label: {
                        HStack {
                            Label("Swipe Left", systemImage: "arrow.left.circle.fill")
                                .foregroundStyle(.red)
                            Spacer()
                            Text(session.swipeLeftAction.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("SwipeMode Culling")
                } footer: {
                    Text("Swipe left or right on the central canvas in Filmstrip View to rapidly execute single or compound curation actions (e.g. Picked + 5 Stars or Rejected + Red Label) with auto-advancement. Pinch to zoom (1x – 4x) remains active; panning when zoomed will not trigger a swipe. Undo anytime with ⌘Z.")
                }

                Section {
                    Picker("Shortcut Profile", selection: $session.shortcutProfileKind) {
                        ForEach(ShortcutProfileKind.allCases.filter { $0 != .custom || session.shortcutProfileKind == .custom }, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    Toggle("Auto-Advance Selection (A)", isOn: $session.isAutoAdvanceEnabled)
                } header: {
                    Text("Shortcuts & Auto-Advance")
                } footer: {
                    Text("Lightroom profile maps ratings 0–5, flags P/X/U, labels 6–9. Capture One profile maps ratings 0–5, flags +/-/U, label *. Auto-Advance automatically moves selection to the next item immediately after applying a rating, flag, or label.")
                }

                Section("Preview & Discovery Defaults") {
                    Picker("Default PreviewSource", selection: $session.previewSource) {
                        Text("Prefer Raster (JPEG/HEIC)").tag(PreviewSource.preferRaster)
                        Text("Prefer RAW Embedded Preview").tag(PreviewSource.preferRAW)
                    }

                    Toggle("Subfolder Mode", isOn: $session.isRecursiveSubfolderMode)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Pickture Settings")
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
    }
}

// MARK: - Swipe Action Detail Editor View

private enum PickFlagSelection: Hashable {
    case unchanged
    case flag(PickFlag)
}

private enum StarRatingSelection: Hashable {
    case unchanged
    case rating(Int)
}

private enum ColorLabelSelection: Hashable {
    case unchanged
    case color(ColorLabel)
}

struct SwipeActionDetailEditorView: View {
    let title: String
    let direction: SwipeDirection
    @Binding var action: CurationAction

    private var pickFlagBinding: Binding<PickFlagSelection> {
        Binding(
            get: {
                if let flag = action.pickFlagValue {
                    return .flag(flag)
                }
                return .unchanged
            },
            set: { newSelection in
                let flag: PickFlag? = switch newSelection {
                case .unchanged: nil
                case .flag(let f): f
                }
                action = CurationAction.make(
                    starRating: action.starRatingValue,
                    pickFlag: flag,
                    colorLabel: action.colorLabelValue
                )
            }
        )
    }

    private var starRatingBinding: Binding<StarRatingSelection> {
        Binding(
            get: {
                if let rating = action.starRatingValue {
                    return .rating(rating.value)
                }
                return .unchanged
            },
            set: { newSelection in
                let rating: StarRating? = switch newSelection {
                case .unchanged: nil
                case .rating(let r): StarRating(r)
                }
                action = CurationAction.make(
                    starRating: rating,
                    pickFlag: action.pickFlagValue,
                    colorLabel: action.colorLabelValue
                )
            }
        )
    }

    private var colorLabelBinding: Binding<ColorLabelSelection> {
        Binding(
            get: {
                if let label = action.colorLabelValue {
                    return .color(label)
                }
                return .unchanged
            },
            set: { newSelection in
                let label: ColorLabel? = switch newSelection {
                case .unchanged: nil
                case .color(let c): c
                }
                action = CurationAction.make(
                    starRating: action.starRatingValue,
                    pickFlag: action.pickFlagValue,
                    colorLabel: label
                )
            }
        )
    }

    var body: some View {
        Form {
            Section("Current Configuration") {
                HStack {
                    Text("Action Summary")
                    Spacer()
                    Text(action.displayName)
                        .font(.headline)
                        .foregroundStyle(direction == .right ? .green : .red)
                }

                HStack {
                    Text("Action Badge Preview")
                    Spacer()
                    SwipeActionBadgeView(action: action, direction: direction)
                        .scaleEffect(0.8)
                }
            }

            Section("Quick Presets") {
                if direction == .right {
                    Button("Default: Picked") {
                        action = .setPickFlag(.picked)
                    }
                    Button("Compound: Picked + 5 Stars") {
                        action = .compound(starRating: 5, pickFlag: .picked)
                    }
                    Button("Single: 5 Stars") {
                        action = .setStarRating(5)
                    }
                    Button("Compound: Picked + Green Label") {
                        action = .compound(pickFlag: .picked, colorLabel: .green)
                    }
                } else {
                    Button("Default: Rejected") {
                        action = .setPickFlag(.rejected)
                    }
                    Button("Compound: Rejected + Red Label") {
                        action = .compound(pickFlag: .rejected, colorLabel: .red)
                    }
                    Button("Single: Red Label") {
                        action = .setColorLabel(.red)
                    }
                    Button("Single: Unflagged") {
                        action = .setPickFlag(.unflagged)
                    }
                }
            }

            Section("Attributes (Combine for Compound Action)") {
                Picker("Pick Flag", selection: pickFlagBinding) {
                    Text("-- (Unchanged)").tag(PickFlagSelection.unchanged)
                    Text("Picked (P)").tag(PickFlagSelection.flag(.picked))
                    Text("Rejected (X)").tag(PickFlagSelection.flag(.rejected))
                    Text("Unflagged (U)").tag(PickFlagSelection.flag(.unflagged))
                }

                Picker("Star Rating", selection: starRatingBinding) {
                    Text("-- (Unchanged)").tag(StarRatingSelection.unchanged)
                    Text("0 Stars (Unrated)").tag(StarRatingSelection.rating(0))
                    ForEach(1...5, id: \.self) { star in
                        Text("\(star) Star\(star == 1 ? "" : "s")").tag(StarRatingSelection.rating(star))
                    }
                }

                Picker("Color Label", selection: colorLabelBinding) {
                    Text("-- (Unchanged)").tag(ColorLabelSelection.unchanged)
                    Text("Clear Color (None)").tag(ColorLabelSelection.color(.none))
                    ForEach(ColorLabel.allCases.filter { $0 != .none }, id: \.self) { label in
                        HStack {
                            Circle()
                                .fill(label.displayColor)
                                .frame(width: 10, height: 10)
                            Text(label.rawValue.capitalized)
                        }
                        .tag(ColorLabelSelection.color(label))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }
}

