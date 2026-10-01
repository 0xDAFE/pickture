import SwiftUI

struct FilterCriteriaBarView: View {
    @Bindable var session: CullingSession
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // MARK: - Search Query
                    searchField
                        .frame(width: 180)

                    Divider()
                        .frame(height: 18)

                    // MARK: - Star Rating & Pick Flags
                    ratingAndPickMenu

                    // MARK: - Color Labels
                    colorLabelMenu

                    // MARK: - Camera Model
                    cameraModelMenu

                    // MARK: - Lens Model
                    lensModelMenu

                    // MARK: - Media Type
                    mediaTypeMenu

                    // MARK: - Sync State
                    syncStateMenu

                    Divider()
                        .frame(height: 18)

                    // MARK: - Active Filter Badge & Reset
                    if session.filterCriteria.isActive {
                        activeBadgeAndResetButton
                    }

                    Spacer(minLength: 8)

                    // MARK: - Sort Menu
                    sortMenu
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)

            Divider()
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("Filter filename…", text: $session.filterCriteria.searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($isSearchFocused)

            if !session.filterCriteria.searchQuery.isEmpty {
                Button {
                    session.filterCriteria.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filename filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
        )
    }

    // MARK: - Rating & Pick Menu

    private var ratingAndPickMenu: some View {
        let isRatingActive = session.filterCriteria.isStarRatingActive
        let isPickActive = session.filterCriteria.isPickFlagActive
        let isActive = isRatingActive || isPickActive

        return Menu {
            // Mode toggle
            let currentMode = session.filterCriteria.starRatingFilter?.mode ?? .exact
            Section("Rating Filter Mode") {
                Button {
                    var filter = session.filterCriteria.starRatingFilter ?? StarRatingFilter(mode: .minimum, minimumRating: 1)
                    filter.mode = .minimum
                    session.filterCriteria.starRatingFilter = filter
                } label: {
                    Label("Minimum (≥)", systemImage: currentMode == .minimum ? "checkmark" : "")
                }

                Button {
                    var filter = session.filterCriteria.starRatingFilter ?? StarRatingFilter(mode: .exact)
                    filter.mode = .exact
                    session.filterCriteria.starRatingFilter = filter
                } label: {
                    Label("Exact Rating", systemImage: currentMode == .exact ? "checkmark" : "")
                }
            }

            if currentMode == .minimum {
                Section("Minimum Star Rating (≥)") {
                    ForEach([1, 2, 3, 4, 5], id: \.self) { minVal in
                        let isSelected = session.filterCriteria.starRatingFilter?.minimumRating == minVal && isRatingActive
                        Button {
                            if isSelected {
                                session.filterCriteria.starRatingFilter = nil
                            } else {
                                session.filterCriteria.starRatingFilter = .minimum(minVal)
                            }
                        } label: {
                            Label(
                                "≥ \(minVal) Star\(minVal == 1 ? "" : "s")",
                                systemImage: isSelected ? "checkmark" : ""
                            )
                        }
                    }
                }
            } else {
                Section("Exact Star Ratings (OR)") {
                    ForEach([5, 4, 3, 2, 1, 0], id: \.self) { ratingVal in
                        let exactRatings = session.filterCriteria.starRatingFilter?.exactRatings ?? []
                        let isSelected = exactRatings.contains(ratingVal)
                        Button {
                            var filter = session.filterCriteria.starRatingFilter ?? StarRatingFilter(mode: .exact)
                            filter.mode = .exact
                            if isSelected {
                                filter.exactRatings.remove(ratingVal)
                            } else {
                                filter.exactRatings.insert(ratingVal)
                            }
                            session.filterCriteria.starRatingFilter = filter.exactRatings.isEmpty ? nil : filter
                        } label: {
                            let labelText = ratingVal == 0 ? "0 Stars (Unrated)" : "\(ratingVal) Star\(ratingVal == 1 ? "" : "s")"
                            Label(labelText, systemImage: isSelected ? "checkmark" : "")
                        }
                    }
                }
            }

            Section("Pick Flags (OR)") {
                ForEach(PickFlag.allCases, id: \.self) { flag in
                    let isSelected = session.filterCriteria.pickFlags.contains(flag)
                    Button {
                        if isSelected {
                            session.filterCriteria.pickFlags.remove(flag)
                        } else {
                            session.filterCriteria.pickFlags.insert(flag)
                        }
                    } label: {
                        Label(flag.rawValue.capitalized, systemImage: isSelected ? "checkmark" : "")
                    }
                }
            }

            if isActive {
                Section {
                    Button(role: .destructive) {
                        session.filterCriteria.starRatingFilter = nil
                        session.filterCriteria.pickFlags.removeAll()
                    } label: {
                        Label("Clear Rating & Pick Filters", systemImage: "xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "star.fill" : "star")
                    .foregroundStyle(isActive ? Color.yellow : Color.secondary)
                Text(ratingAndPickTitle)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.yellow.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    private var ratingAndPickTitle: String {
        var parts: [String] = []
        if let ratingFilter = session.filterCriteria.starRatingFilter, session.filterCriteria.isStarRatingActive {
            switch ratingFilter.mode {
            case .minimum:
                parts.append("≥\(ratingFilter.minimumRating)★")
            case .exact:
                let sorted = ratingFilter.exactRatings.sorted()
                parts.append(sorted.map { "\($0)★" }.joined(separator: ","))
            }
        }
        if !session.filterCriteria.pickFlags.isEmpty {
            let names = session.filterCriteria.pickFlags.map { $0.rawValue.capitalized }.sorted()
            parts.append(names.joined(separator: ","))
        }
        return parts.isEmpty ? "Rating / Pick" : parts.joined(separator: " • ")
    }

    // MARK: - Color Label Menu

    private var colorLabelMenu: some View {
        let isActive = session.filterCriteria.isColorLabelActive

        return Menu {
            Section("Color Labels (OR)") {
                ForEach(ColorLabel.allCases, id: \.self) { label in
                    let isSelected = session.filterCriteria.colorLabels.contains(label)
                    Button {
                        if isSelected {
                            session.filterCriteria.colorLabels.remove(label)
                        } else {
                            session.filterCriteria.colorLabels.insert(label)
                        }
                    } label: {
                        Label(
                            label == .none ? "None" : label.rawValue.capitalized,
                            systemImage: isSelected ? "checkmark" : ""
                        )
                    }
                }
            }

            if isActive {
                Section {
                    Button(role: .destructive) {
                        session.filterCriteria.colorLabels.removeAll()
                    } label: {
                        Label("Clear Color Labels", systemImage: "xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "\(session.filterCriteria.colorLabels.count) Color\(session.filterCriteria.colorLabels.count == 1 ? "" : "s")" : "Color")
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Camera Model Menu

    private var cameraModelMenu: some View {
        let isActive = session.filterCriteria.isCameraModelActive
        let available = session.availableCameraModels

        return Menu {
            if available.isEmpty {
                Text("No Camera Models Detected")
            } else {
                Section("Camera Models (OR)") {
                    ForEach(available, id: \.self) { model in
                        let isSelected = session.filterCriteria.cameraModels.contains(model)
                        Button {
                            if isSelected {
                                session.filterCriteria.cameraModels.remove(model)
                            } else {
                                session.filterCriteria.cameraModels.insert(model)
                            }
                        } label: {
                            Label(model, systemImage: isSelected ? "checkmark" : "")
                        }
                    }
                }
            }

            if isActive {
                Section {
                    Button(role: .destructive) {
                        session.filterCriteria.cameraModels.removeAll()
                    } label: {
                        Label("Clear Camera Filters", systemImage: "xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "camera")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "\(session.filterCriteria.cameraModels.count) Camera\(session.filterCriteria.cameraModels.count == 1 ? "" : "s")" : "Camera")
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lens Model Menu

    private var lensModelMenu: some View {
        let isActive = session.filterCriteria.isLensModelActive
        let available = session.availableLensModels

        return Menu {
            if available.isEmpty {
                Text("No Lens Models Detected")
            } else {
                Section("Lens Models (OR)") {
                    ForEach(available, id: \.self) { lens in
                        let isSelected = session.filterCriteria.lensModels.contains(lens)
                        Button {
                            if isSelected {
                                session.filterCriteria.lensModels.remove(lens)
                            } else {
                                session.filterCriteria.lensModels.insert(lens)
                            }
                        } label: {
                            Label(lens, systemImage: isSelected ? "checkmark" : "")
                        }
                    }
                }
            }

            if isActive {
                Section {
                    Button(role: .destructive) {
                        session.filterCriteria.lensModels.removeAll()
                    } label: {
                        Label("Clear Lens Filters", systemImage: "xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "\(session.filterCriteria.lensModels.count) Lens\(session.filterCriteria.lensModels.count == 1 ? "" : "es")" : "Lens")
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Media Type Menu

    private var mediaTypeMenu: some View {
        let isActive = session.filterCriteria.isMediaTypeActive

        return Menu {
            Section("Media Type (OR)") {
                ForEach(MediaTypeFilter.allCases, id: \.self) { type in
                    let isSelected = session.filterCriteria.mediaTypes.contains(type)
                    Button {
                        if isSelected {
                            session.filterCriteria.mediaTypes.remove(type)
                        } else {
                            session.filterCriteria.mediaTypes.insert(type)
                        }
                    } label: {
                        Label(type.displayName, systemImage: isSelected ? "checkmark" : "")
                    }
                }
            }

            if isActive {
                Section {
                    Button(role: .destructive) {
                        session.filterCriteria.mediaTypes.removeAll()
                    } label: {
                        Label("Clear Media Type Filters", systemImage: "xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo.stack")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "\(session.filterCriteria.mediaTypes.count) Type\(session.filterCriteria.mediaTypes.count == 1 ? "" : "s")" : "Type")
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sync State Menu

    private var syncStateMenu: some View {
        let isActive = session.filterCriteria.isSyncStateActive

        return Menu {
            Section("Sync State (OR)") {
                ForEach([SyncState.synced, .pendingWrite, .conflicted, .syncError], id: \.self) { state in
                    let isSelected = session.filterCriteria.syncStates.contains(state)
                    Button {
                        if isSelected {
                            session.filterCriteria.syncStates.remove(state)
                        } else {
                            session.filterCriteria.syncStates.insert(state)
                        }
                    } label: {
                        Label(stateDisplayName(state), systemImage: isSelected ? "checkmark" : "")
                    }
                }
            }

            if isActive {
                Section {
                    Button(role: .destructive) {
                        session.filterCriteria.syncStates.removeAll()
                    } label: {
                        Label("Clear Sync State Filters", systemImage: "xmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "\(session.filterCriteria.syncStates.count) State\(session.filterCriteria.syncStates.count == 1 ? "" : "s")" : "Sync")
                    .font(.caption.weight(isActive ? .semibold : .regular))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    private func stateDisplayName(_ state: SyncState) -> String {
        switch state {
        case .synced: return "Synced"
        case .pendingWrite: return "Pending Write"
        case .conflicted: return "Conflicted"
        case .syncError: return "Sync Error"
        case .loading: return "Loading"
        }
    }

    // MARK: - Active Badge & Reset Button

    private var activeBadgeAndResetButton: some View {
        HStack(spacing: 6) {
            Text("\(session.filterCriteria.activeFilterCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Circle().fill(Color.accentColor))

            Button {
                session.resetFilters()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                    Text("Reset Filters")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Clear all active filters")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            Section("Sort Field") {
                ForEach(SortField.allCases, id: \.self) { field in
                    Button {
                        session.setSortField(field)
                    } label: {
                        Label(field.displayName, systemImage: session.sortOption.field == field ? "checkmark" : "")
                    }
                }
            }

            Section("Sort Direction") {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Button {
                        session.setSortOrder(order)
                    } label: {
                        Label(order.displayName, systemImage: session.sortOption.order == order ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(Color.secondary)
                Text("\(session.sortOption.field.displayName) (\(session.sortOption.order.displayName))")
                    .font(.caption.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .help("Sort visible MediaItems by Filename, Capture Date, or Star Rating")
    }
}
