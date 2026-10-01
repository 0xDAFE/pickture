import Foundation
import SwiftUI
import Testing
@testable import Pickture

@MainActor
struct ContentViewDecompositionTests {

    @Test("SidebarContentView supports injected session and callback closures")
    func sidebarContentViewInitialization() {
        let session = CullingSession()
        var closedFolder = false
        var reopenedFolder: RecentFolder?

        let sidebar = SidebarContentView(
            session: session,
            onCloseFolder: { closedFolder = true },
            onReopenRecentFolder: { reopenedFolder = $0 }
        )
        #expect(sidebar.session === session)

        sidebar.onCloseFolder()
        #expect(closedFolder == true)

        let dummyRecent = RecentFolder(
            id: "test-id",
            name: "Shoot1",
            displayPath: "/path/Shoot1",
            bookmarkData: Data(),
            lastOpenedAt: Date()
        )
        sidebar.onReopenRecentFolder(dummyRecent)
        #expect(reopenedFolder == dummyRecent)
    }

    @Test("EmptyWorkspaceView supports initialization with recent folders list and injected session")
    func emptyWorkspaceViewInitialization() {
        let dummyRecent = RecentFolder(
            id: "rec-1",
            name: "Wedding",
            displayPath: "/photos/Wedding",
            bookmarkData: Data(),
            lastOpenedAt: Date()
        )
        var reopened: RecentFolder?

        let viewFromList = EmptyWorkspaceView(
            recentFolders: [dummyRecent],
            onReopenRecentFolder: { reopened = $0 }
        )
        #expect(viewFromList.recentFolders.count == 1)
        #expect(viewFromList.recentFolders.first?.name == "Wedding")

        viewFromList.onReopenRecentFolder(dummyRecent)
        #expect(reopened == dummyRecent)

        let session = CullingSession()
        let viewFromSession = EmptyWorkspaceView(session: session)
        #expect(viewFromSession.recentFolders == session.recentFolders)
    }

    @Test("GridContentView supports injected session and custom grid columns")
    func gridContentViewInitialization() {
        let session = CullingSession()
        let defaultGrid = GridContentView(session: session)
        #expect(defaultGrid.session === session)
        #expect(defaultGrid.gridColumns.count == 1)

        let customColumns = [GridItem(.fixed(200)), GridItem(.fixed(200))]
        let customGrid = GridContentView(session: session, gridColumns: customColumns)
        #expect(customGrid.gridColumns.count == 2)
    }

    @Test("PicktureToolbarContent conforms to ToolbarContent and supports injected parameters")
    func picktureToolbarContentInitialization() {
        let session = CullingSession()
        var reopened: RecentFolder?

        let toolbar = PicktureToolbarContent(
            session: session,
            horizontalSizeClass: .regular,
            onReopenRecentFolder: { reopened = $0 }
        )
        #expect(toolbar.session === session)
        #expect(toolbar.horizontalSizeClass == .regular)

        let dummyRecent = RecentFolder(
            id: "rec-2",
            name: "Portrait",
            displayPath: "/photos/Portrait",
            bookmarkData: Data(),
            lastOpenedAt: Date()
        )
        toolbar.onReopenRecentFolder(dummyRecent)
        #expect(reopened == dummyRecent)
    }

    @Test("ContentView instantiates subviews and binds session")
    func contentViewInitialization() {
        let session = CullingSession()
        let contentView = ContentView(session: session)
        #expect(contentView.session === session)
    }
}
