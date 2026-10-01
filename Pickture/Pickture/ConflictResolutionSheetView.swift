import SwiftUI

struct ConflictResolutionSheetView: View {
    @Bindable var session: CullingSession
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItemID: String?
    @State private var cherryPickedMetadata: CurationMetadata = CurationMetadata()
    @State private var isResolving = false

    private var conflictedItems: [MediaItem] {
        session.conflictedItems
    }

    private var currentItem: MediaItem? {
        if let selectedItemID, let item = conflictedItems.first(where: { $0.id == selectedItemID }) {
            return item
        }
        return conflictedItems.first
    }

    private var currentConflict: MetadataConflict? {
        guard let item = currentItem else { return nil }
        return session.conflict(for: item)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if conflictedItems.isEmpty {
                    allResolvedView
                } else {
                    mainConflictContentView
                }
            }
            .navigationTitle("3-Way Metadata Conflict Resolution")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            initializeSelection()
        }
        .onChange(of: session.activeConflictItemID) { _, newID in
            if let newID {
                selectedItemID = newID
            }
            initializeCherryPick()
        }
        .onChange(of: conflictedItems.count) { _, newCount in
            if newCount == 0 {
                session.activeConflictItemID = nil
            } else if currentItem == nil {
                selectedItemID = conflictedItems.first?.id
                initializeCherryPick()
            }
        }
    }

    private var allResolvedView: some View {
        ContentUnavailableView {
            Label("All Conflicts Resolved", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } description: {
            Text("All sidecars on disk have been synchronized with your curation decisions.")
        } actions: {
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var mainConflictContentView: some View {
        VStack(spacing: 0) {
            // Batch Actions Bar (when multiple items are conflicted)
            if conflictedItems.count > 1 {
                HStack(spacing: 16) {
                    Label(
                        "\(conflictedItems.count) Conflicted MediaItems",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                    Spacer()

                    Button {
                        resolveAllWithLocal()
                    } label: {
                        Text("Use Local for All (\(conflictedItems.count))")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isResolving)

                    Button {
                        resolveAllWithRemote()
                    } label: {
                        Text("Use Remote for All (\(conflictedItems.count))")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isResolving)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.orange.opacity(0.1))
                Divider()
            }

            // Conflicted items selector tab bar if > 1
            if conflictedItems.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(conflictedItems) { item in
                            Button {
                                selectedItemID = item.id
                                initializeCherryPick()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text(item.displayFileName)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(item.id == currentItem?.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                Divider()
            }

            if let item = currentItem, let conflict = currentConflict {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header info
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayFileName)
                                    .font(.title3.weight(.bold))
                                if !item.relativeDirectoryPath.isEmpty {
                                    Text(item.relativeDirectoryPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(item.badgeText)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.75), in: Capsule())
                                .foregroundStyle(.yellow)
                        }

                        // 3-Way Comparison Card
                        threeWayComparisonCard(conflict: conflict)

                        // Per-Field Cherry-Picking Editor
                        cherryPickingSection(conflict: conflict)

                        // Action Buttons for this item
                        HStack(spacing: 12) {
                            Button {
                                resolveCurrentItem(strategy: .useLocal)
                            } label: {
                                Label("Use Local (Pickture)", systemImage: "arrow.left.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button {
                                resolveCurrentItem(strategy: .useRemote)
                            } label: {
                                Label("Use Remote (Disk .xmp)", systemImage: "arrow.right.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button {
                                resolveCurrentItem(strategy: .cherryPick(cherryPickedMetadata))
                            } label: {
                                Label("Apply Cherry-Pick", systemImage: "slider.horizontal.3")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .disabled(isResolving)
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("No Conflict Selected", systemImage: "questionmark")
            }
        }
    }

    private func threeWayComparisonCard(conflict: MetadataConflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3-Way Metadata Comparison")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Field")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("Base Snapshot")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("Local (Pickture)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text("Remote (Disk .xmp)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
                Divider()

                // Star Rating
                GridRow {
                    HStack(spacing: 4) {
                        if conflict.starRatingDiff.isConflicted {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                        }
                        Text("Star Rating")
                            .font(.subheadline.weight(.semibold))
                    }
                    fieldValueView(rating: conflict.base?.starRating)
                    fieldValueView(rating: conflict.local.starRating, isLocal: true)
                    fieldValueView(rating: conflict.remote.starRating, isRemote: true)
                }

                Divider()

                // Pick Flag
                GridRow {
                    HStack(spacing: 4) {
                        if conflict.pickFlagDiff.isConflicted {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                        }
                        Text("Pick Flag")
                            .font(.subheadline.weight(.semibold))
                    }
                    fieldValueView(flag: conflict.base?.pickFlag)
                    fieldValueView(flag: conflict.local.pickFlag, isLocal: true)
                    fieldValueView(flag: conflict.remote.pickFlag, isRemote: true)
                }

                Divider()

                // Color Label
                GridRow {
                    HStack(spacing: 4) {
                        if conflict.colorLabelDiff.isConflicted {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption2)
                        }
                        Text("Color Label")
                            .font(.subheadline.weight(.semibold))
                    }
                    fieldValueView(label: conflict.base?.colorLabel)
                    fieldValueView(label: conflict.local.colorLabel, isLocal: true)
                    fieldValueView(label: conflict.remote.colorLabel, isRemote: true)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.35))
            )
        }
    }

    private func cherryPickingSection(conflict: MetadataConflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cherry-Pick Fields")
                .font(.headline)

            VStack(spacing: 12) {
                // Star Rating Picker
                HStack {
                    Text("Star Rating")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 120, alignment: .leading)

                    Picker("Star Rating", selection: $cherryPickedMetadata.starRating) {
                        Text("0 Stars (Unrated)").tag(StarRating(0))
                        ForEach(1...5, id: \.self) { stars in
                            Text("\(stars) ★").tag(StarRating(stars))
                        }
                    }
                    .pickerStyle(.segmented)

                    Button("Local (\(conflict.local.starRating.value)★)") {
                        cherryPickedMetadata.starRating = conflict.local.starRating
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Remote (\(conflict.remote.starRating.value)★)") {
                        cherryPickedMetadata.starRating = conflict.remote.starRating
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Pick Flag Picker
                HStack {
                    Text("Pick Flag")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 120, alignment: .leading)

                    Picker("Pick Flag", selection: $cherryPickedMetadata.pickFlag) {
                        Text("Unflagged").tag(PickFlag.unflagged)
                        Text("Picked").tag(PickFlag.picked)
                        Text("Rejected").tag(PickFlag.rejected)
                    }
                    .pickerStyle(.segmented)

                    Button("Local (\(conflict.local.pickFlag.rawValue.capitalized))") {
                        cherryPickedMetadata.pickFlag = conflict.local.pickFlag
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Remote (\(conflict.remote.pickFlag.rawValue.capitalized))") {
                        cherryPickedMetadata.pickFlag = conflict.remote.pickFlag
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Color Label Picker
                HStack {
                    Text("Color Label")
                        .font(.subheadline.weight(.medium))
                        .frame(width: 120, alignment: .leading)

                    Picker("Color Label", selection: $cherryPickedMetadata.colorLabel) {
                        ForEach(ColorLabel.allCases, id: \.self) { label in
                            Text(label.rawValue.capitalized).tag(label)
                        }
                    }

                    Button("Local (\(conflict.local.colorLabel.rawValue.capitalized))") {
                        cherryPickedMetadata.colorLabel = conflict.local.colorLabel
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Remote (\(conflict.remote.colorLabel.rawValue.capitalized))") {
                        cherryPickedMetadata.colorLabel = conflict.remote.colorLabel
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary.opacity(0.35))
            )
        }
    }

    @ViewBuilder
    private func fieldValueView(rating: StarRating?, isLocal: Bool = false, isRemote: Bool = false) -> some View {
        if let rating {
            HStack(spacing: 2) {
                if rating.value == 0 {
                    Text("Unrated (0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(1...5, id: \.self) { index in
                        Image(systemName: index <= rating.value ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(index <= rating.value ? .yellow : .secondary.opacity(0.4))
                    }
                    Text("(\(rating.value))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func fieldValueView(flag: PickFlag?, isLocal: Bool = false, isRemote: Bool = false) -> some View {
        if let flag {
            HStack(spacing: 4) {
                switch flag {
                case .picked:
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.white)
                    Text("Picked")
                case .unflagged:
                    Image(systemName: "flag")
                        .foregroundStyle(.secondary)
                    Text("Unflagged")
                case .rejected:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text("Rejected")
                }
            }
            .font(.caption.weight(.medium))
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func fieldValueView(label: ColorLabel?, isLocal: Bool = false, isRemote: Bool = false) -> some View {
        if let label {
            HStack(spacing: 6) {
                Circle()
                    .fill(label == .none ? Color.secondary.opacity(0.3) : label.displayColor)
                    .frame(width: 10, height: 10)
                Text(label.rawValue.capitalized)
                    .font(.caption.weight(.medium))
            }
        } else {
            Text("—")
                .foregroundStyle(.tertiary)
        }
    }

    private func initializeSelection() {
        if let activeID = session.activeConflictItemID,
           conflictedItems.contains(where: { $0.id == activeID }) {
            selectedItemID = activeID
        } else {
            selectedItemID = conflictedItems.first?.id
        }
        initializeCherryPick()
    }

    private func initializeCherryPick() {
        if let conflict = currentConflict {
            // Default cherry-pick combines local rating/flag and remote label or local
            self.cherryPickedMetadata = conflict.local
        }
    }

    private func resolveCurrentItem(strategy: ConflictResolutionStrategy) {
        guard let item = currentItem else { return }
        isResolving = true
        Task {
            do {
                try await session.resolveConflict(for: item, strategy: strategy)
                isResolving = false
                if let next = conflictedItems.first {
                    selectedItemID = next.id
                    initializeCherryPick()
                } else {
                    session.isConflictSheetPresented = false
                }
            } catch {
                isResolving = false
                session.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func resolveAllWithLocal() {
        isResolving = true
        Task {
            do {
                try await session.resolveAllConflictsWithLocal()
                isResolving = false
                session.isConflictSheetPresented = false
            } catch {
                isResolving = false
                session.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func resolveAllWithRemote() {
        isResolving = true
        Task {
            do {
                try await session.resolveAllConflictsWithRemote()
                isResolving = false
                session.isConflictSheetPresented = false
            } catch {
                isResolving = false
                session.lastErrorMessage = error.localizedDescription
            }
        }
    }
}
