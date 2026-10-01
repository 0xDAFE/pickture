import SwiftUI

struct FilterCriteriaBarView: View {
    @Bindable var session: CullingSession
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    fullBarContent
                    mediumBarContent
                    compactBarContent
                    ScrollView(.horizontal, showsIndicators: false) {
                        compactBarContent
                    }
                }

                Spacer(minLength: 4)

                sortMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()
        }
    }

    // MARK: - Layout Tiers

    private var fullBarContent: some View {
        HStack(spacing: 8) {
            searchField(idealWidth: 160)

            Divider()
                .frame(height: 18)

            ratingAndPickMenu
            colorLabelMenu
            cameraModelMenu
            lensModelMenu
            mediaTypeMenu
            syncStateMenu

            if session.filterCriteria.isActive {
                Divider()
                    .frame(height: 18)
                activeBadgeAndResetButton
            }
        }
    }

    private var mediumBarContent: some View {
        HStack(spacing: 8) {
            searchField(idealWidth: 130)

            Divider()
                .frame(height: 18)

            ratingAndPickMenu
            colorLabelMenu
            overflowMetadataMenu

            if session.filterCriteria.isActive {
                Divider()
                    .frame(height: 18)
                activeBadgeAndResetButton
            }
        }
    }

    private var compactBarContent: some View {
        HStack(spacing: 8) {
            searchField(idealWidth: 110)

            Divider()
                .frame(height: 18)

            allFiltersMenu

            if session.filterCriteria.isActive {
                Divider()
                    .frame(height: 18)
                activeBadgeAndResetButton
            }
        }
    }

    // MARK: - Search Field

    private func searchField(idealWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)

            TextField("Filter filename…", text: $session.filterCriteria.searchQuery)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($isSearchFocused)
                .onChange(of: isSearchFocused) { _, newValue in
                    session.isSearchFieldFocused = newValue
                }
                .onChange(of: session.isSearchFieldFocused) { _, newValue in
                    if isSearchFocused != newValue {
                        isSearchFocused = newValue
                    }
                }
                .onKeyPress(.escape) {
                    if !session.filterCriteria.searchQuery.isEmpty {
                        session.filterCriteria.searchQuery = ""
                    } else {
                        isSearchFocused = false
                    }
                    return .handled
                }
                .onSubmit {
                    isSearchFocused = false
                }

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
        .frame(minWidth: 80, idealWidth: idealWidth, maxWidth: idealWidth + 40)
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
            ratingAndPickMenuContent
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

    @ViewBuilder
    private var ratingAndPickMenuContent: some View {
        let isRatingActive = session.filterCriteria.isStarRatingActive
        let isPickActive = session.filterCriteria.isPickFlagActive
        let isActive = isRatingActive || isPickActive

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
            colorLabelMenuContent
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

    @ViewBuilder
    private var colorLabelMenuContent: some View {
        let isActive = session.filterCriteria.isColorLabelActive

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
    }

    // MARK: - Camera Model Menu

    private var cameraModelMenu: some View {
        let isActive = session.filterCriteria.isCameraModelActive

        return Menu {
            cameraModelMenuContent
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

    @ViewBuilder
    private var cameraModelMenuContent: some View {
        let isActive = session.filterCriteria.isCameraModelActive
        let available = session.availableCameraModels

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
    }

    // MARK: - Lens Model Menu

    private var lensModelMenu: some View {
        let isActive = session.filterCriteria.isLensModelActive

        return Menu {
            lensModelMenuContent
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

    @ViewBuilder
    private var lensModelMenuContent: some View {
        let isActive = session.filterCriteria.isLensModelActive
        let available = session.availableLensModels

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
    }

    // MARK: - Media Type Menu

    private var mediaTypeMenu: some View {
        let isActive = session.filterCriteria.isMediaTypeActive

        return Menu {
            mediaTypeMenuContent
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

    @ViewBuilder
    private var mediaTypeMenuContent: some View {
        let isActive = session.filterCriteria.isMediaTypeActive

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
    }

    // MARK: - Sync State Menu

    private var syncStateMenu: some View {
        let isActive = session.filterCriteria.isSyncStateActive

        return Menu {
            syncStateMenuContent
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

    @ViewBuilder
    private var syncStateMenuContent: some View {
        let isActive = session.filterCriteria.isSyncStateActive

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
    }

    // MARK: - Overflow Metadata Menu (Tier 2)

    private var overflowMetadataMenu: some View {
        let isCameraActive = session.filterCriteria.isCameraModelActive
        let isLensActive = session.filterCriteria.isLensModelActive
        let isTypeActive = session.filterCriteria.isMediaTypeActive
        let isSyncActive = session.filterCriteria.isSyncStateActive
        let activeCount = (isCameraActive ? 1 : 0) + (isLensActive ? 1 : 0) + (isTypeActive ? 1 : 0) + (isSyncActive ? 1 : 0)
        let isActive = activeCount > 0

        return Menu {
            Menu {
                cameraModelMenuContent
            } label: {
                Label(isCameraActive ? "Camera (\(session.filterCriteria.cameraModels.count))" : "Camera", systemImage: "camera")
            }

            Menu {
                lensModelMenuContent
            } label: {
                Label(isLensActive ? "Lens (\(session.filterCriteria.lensModels.count))" : "Lens", systemImage: "circle.circle")
            }

            Menu {
                mediaTypeMenuContent
            } label: {
                Label(isTypeActive ? "Type (\(session.filterCriteria.mediaTypes.count))" : "Media Type", systemImage: "photo.stack")
            }

            Menu {
                syncStateMenuContent
            } label: {
                Label(isSyncActive ? "Sync (\(session.filterCriteria.syncStates.count))" : "Sync State", systemImage: "arrow.triangle.2.circlepath")
            }

            if isActive {
                Divider()
                Button(role: .destructive) {
                    session.filterCriteria.cameraModels.removeAll()
                    session.filterCriteria.lensModels.removeAll()
                    session.filterCriteria.mediaTypes.removeAll()
                    session.filterCriteria.syncStates.removeAll()
                } label: {
                    Label("Clear Metadata Filters", systemImage: "xmark")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "Metadata (\(activeCount))" : "Metadata")
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

    // MARK: - All Filters Menu (Tier 3 Compact)

    private var allFiltersMenu: some View {
        let isActive = session.filterCriteria.isActive

        return Menu {
            Menu {
                ratingAndPickMenuContent
            } label: {
                Label(session.filterCriteria.isStarRatingActive || session.filterCriteria.isPickFlagActive ? "Rating & Pick (\(ratingAndPickTitle))" : "Rating & Pick", systemImage: "star")
            }

            Menu {
                colorLabelMenuContent
            } label: {
                Label(session.filterCriteria.isColorLabelActive ? "Color (\(session.filterCriteria.colorLabels.count))" : "Color", systemImage: "tag")
            }

            Menu {
                cameraModelMenuContent
            } label: {
                Label(session.filterCriteria.isCameraModelActive ? "Camera (\(session.filterCriteria.cameraModels.count))" : "Camera", systemImage: "camera")
            }

            Menu {
                lensModelMenuContent
            } label: {
                Label(session.filterCriteria.isLensModelActive ? "Lens (\(session.filterCriteria.lensModels.count))" : "Lens", systemImage: "circle.circle")
            }

            Menu {
                mediaTypeMenuContent
            } label: {
                Label(session.filterCriteria.isMediaTypeActive ? "Type (\(session.filterCriteria.mediaTypes.count))" : "Media Type", systemImage: "photo.stack")
            }

            Menu {
                syncStateMenuContent
            } label: {
                Label(session.filterCriteria.isSyncStateActive ? "Sync (\(session.filterCriteria.syncStates.count))" : "Sync State", systemImage: "arrow.triangle.2.circlepath")
            }

            if isActive {
                Divider()
                Button(role: .destructive) {
                    session.resetFilters()
                } label: {
                    Label("Reset All Filters", systemImage: "xmark")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(isActive ? "Filters (\(session.filterCriteria.activeFilterCount))" : "Filters")
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
