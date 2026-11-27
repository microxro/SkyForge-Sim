// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFTerrainCore

@Suite struct GlobalTileQuadtreeTests {
    @Test func originTileAndWorldBounds() throws {
        let t0 = GlobalTileID.containing(latitude: 0, longitude: 0, zoom: 0)
        #expect(t0 == GlobalTileID(zoom: 0, x: 0, y: 0))
        let t1 = GlobalTileID.containing(latitude: 0, longitude: 0, zoom: 1)
        #expect(t1 == GlobalTileID(zoom: 1, x: 1, y: 1))
        let world = try #require(GlobalTileID(zoom: 0, x: 0, y: 0))
        #expect(abs(world.westLongitude + 180) < 1e-9)
        #expect(abs(world.eastLongitude - 180) < 1e-9)
        #expect(abs(world.northLatitude - GlobalTileID.mercatorLatitudeLimit) < 1e-6)
        #expect(abs(world.southLatitude + GlobalTileID.mercatorLatitudeLimit) < 1e-6)
    }

    @Test func centreOfEachTileMapsBackToThatTile() throws {
        for zoom in [0, 3, 10, 14, 18] {
            let n = 1 << zoom
            for (x, y) in [(0, 0), (n / 2, n / 3), (n - 1, n - 1)] {
                let t = try #require(GlobalTileID(zoom: zoom, x: x, y: y))
                let lat = (t.northLatitude + t.southLatitude) / 2
                let lon = (t.westLongitude + t.eastLongitude) / 2
                #expect(GlobalTileID.containing(latitude: lat, longitude: lon, zoom: zoom) == t)
            }
        }
    }

    @Test func longitudeWrapsAndLatitudeClamps() {
        #expect(GlobalTileID.containing(latitude: 0, longitude: 540, zoom: 4) == GlobalTileID.containing(latitude: 0, longitude: -180, zoom: 4))
        let polar = GlobalTileID.containing(latitude: 89.9, longitude: 0, zoom: 5)
        #expect(polar.y == 0)
        let south = GlobalTileID.containing(latitude: -89.9, longitude: 0, zoom: 5)
        #expect(south.y == 31)
    }

    @Test func rejectsOutOfRangeIndicesAndChildrenTileTheParent() throws {
        #expect(GlobalTileID(zoom: 2, x: 4, y: 0) == nil)
        #expect(GlobalTileID(zoom: -1, x: 0, y: 0) == nil)
        #expect(GlobalTileID(zoom: 23, x: 0, y: 0) == nil)
        let parent = try #require(GlobalTileID(zoom: 5, x: 9, y: 12))
        let kids = parent.children
        #expect(kids.count == 4)
        #expect(Set(kids).count == 4)
        #expect(kids.allSatisfy { $0.zoom == 6 && $0.x / 2 == parent.x && $0.y / 2 == parent.y })
        let leaf = try #require(GlobalTileID(zoom: GlobalTileID.maxZoom, x: 0, y: 0))
        #expect(leaf.children.isEmpty)
    }

    @Test func cachePathIsKeyedBySourceAndRejectsTraversal() throws {
        let t = try #require(GlobalTileID(zoom: 10, x: 284, y: 435))
        #expect(t.cachePath(source: "s2c2016", fileExtension: "jpg") == "s2c2016/10/284/435.jpg")
        #expect(t.cachePath(source: "../etc", fileExtension: "jpg") == nil)
        #expect(t.cachePath(source: "", fileExtension: "png") == nil)
        #expect(t.cachePath(source: "terrarium", fileExtension: "png/../x") == nil)
    }

    @Test func selectionCoversCameraAndStaysBounded() {
        // San Francisco at 1 km altitude, 50 km radius.
        let tiles = GlobalTileQuadtree.select(
            latitude: 37.62, longitude: -122.38, altitudeMeters: 1_000,
            radiusMeters: 50_000, minZoom: 3, maxZoom: 16, maxTiles: 400)
        #expect(!tiles.isEmpty)
        #expect(tiles.count <= 400)
        #expect(Set(tiles).count == tiles.count, "no duplicates")
        #expect(tiles.allSatisfy { $0.zoom >= 3 && $0.zoom <= 16 })
        let camera = GlobalTileID.containing(latitude: 37.62, longitude: -122.38, zoom: 16)
        // The tile under the camera is refined until it is no wider than the altitude.
        let under = tiles.filter { t in
            t.zoom == 15 && t.x == camera.x >> 1 && t.y == camera.y >> 1
        }
        #expect(under.count == 1)
        #expect(tiles.contains { $0.zoom == 15 && $0.widthMeters <= 1_000 })
    }

    @Test func fartherTilesAreCoarser() {
        let tiles = GlobalTileQuadtree.select(
            latitude: 0, longitude: 0, altitudeMeters: 500,
            radiusMeters: 300_000, minZoom: 2, maxZoom: 14, maxTiles: 2_000)
        let fine = tiles.filter { $0.zoom == 14 }
        let coarse = tiles.filter { $0.zoom <= 8 }
        #expect(!fine.isEmpty)
        #expect(!coarse.isEmpty)
        // Fine tiles only appear close to the camera; coarse tiles sit near the radius edge.
        #expect(fine.allSatisfy { GlobalTileQuadtree.distanceMeters(from: 0, 0, to: $0) < 100_000 })
        #expect(coarse.allSatisfy { GlobalTileQuadtree.distanceMeters(from: 0, 0, to: $0) > 50_000 })
    }

    @Test func rejectsBadInputsAndRespectsTileCap() {
        #expect(GlobalTileQuadtree.select(latitude: .nan, longitude: 0, altitudeMeters: 0, radiusMeters: 1_000, minZoom: 2, maxZoom: 10, maxTiles: 10).isEmpty)
        #expect(GlobalTileQuadtree.select(latitude: 0, longitude: 0, altitudeMeters: 0, radiusMeters: 0, minZoom: 2, maxZoom: 10, maxTiles: 10).isEmpty)
        let capped = GlobalTileQuadtree.select(
            latitude: 10, longitude: 10, altitudeMeters: 0,
            radiusMeters: 20_000, minZoom: 2, maxZoom: 20, maxTiles: 64)
        #expect(capped.count <= 64)
        #expect(!capped.isEmpty)
    }

    @Test func antimeridianDoesNotCreateAGap() {
        // A camera just west of the dateline must still select tiles on the far side (x = 0).
        let tiles = GlobalTileQuadtree.select(
            latitude: 0, longitude: 179.95, altitudeMeters: 2_000,
            radiusMeters: 30_000, minZoom: 3, maxZoom: 12, maxTiles: 500)
        #expect(tiles.contains { $0.x == 0 })
    }
}
