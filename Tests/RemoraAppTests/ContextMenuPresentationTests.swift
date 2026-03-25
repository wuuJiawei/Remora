import Testing
@testable import RemoraApp

struct ContextMenuPresentationTests {
    @Test
    func iconCatalogCoversSessionAndFileManagerActions() {
        #expect(ContextMenuIconCatalog.newSession == "plus")
        #expect(ContextMenuIconCatalog.rename == "pencil")
        #expect(ContextMenuIconCatalog.splitHorizontal == "rectangle.split.2x1")
        #expect(ContextMenuIconCatalog.reconnect == "arrow.clockwise")
        #expect(ContextMenuIconCatalog.download == "arrow.down.circle")
        #expect(ContextMenuIconCatalog.upload == "arrow.up.circle")
        #expect(ContextMenuIconCatalog.properties == "slider.horizontal.3")
        #expect(ContextMenuIconCatalog.delete == "trash")
    }
}
