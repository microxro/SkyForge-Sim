// SKYFORGE — Apache-2.0
import Testing
@testable import SFWorldGen

@Suite struct WorldCoverTileTests {
    @Test func namesFollowTheBucketConvention() {
        #expect(WorldCoverTileKey(southLat: 36, westLon: -123)?.name == "N36W123")
        #expect(WorldCoverTileKey(southLat: 0, westLon: 0)?.name == "N00E000")
        #expect(WorldCoverTileKey(southLat: -3, westLon: 99)?.name == "S03E099")
        #expect(WorldCoverTileKey(southLat: 36, westLon: -123)?.objectKey
                == "v200/2021/map/ESA_WorldCover_10m_2021_v200_N36W123_Map.tif")
    }

    @Test func invalidKeysAreRejected() {
        #expect(WorldCoverTileKey(southLat: 37, westLon: -123) == nil)
        #expect(WorldCoverTileKey(southLat: 36, westLon: -121) == nil)
        #expect(WorldCoverTileKey(southLat: 90, westLon: 0) == nil)
        #expect(WorldCoverTileKey(southLat: 0, westLon: 180) == nil)
    }

    @Test func containingFindsTheSouthWestCorner() {
        let key = WorldCoverTileKey.containing(latitude: 36.587, longitude: -121.843)
        #expect(key?.name == "N36W123")
        #expect(WorldCoverTileKey.containing(latitude: -0.5, longitude: -0.5)?.name == "S03W003")
    }

    @Test func longitudeWrapsAcrossTheAntimeridian() {
        #expect(WorldCoverTileKey.containing(latitude: 10, longitude: 181)?.westLon == -180)
        #expect(WorldCoverTileKey.containing(latitude: 10, longitude: -181)?.westLon == 177)
    }

    @Test func coveringIsSortedUniqueAndContainsTheCentreTile() {
        let keys = WorldCoverTileKey.covering(latitude: 36.587, longitude: -121.843, radiusMeters: 150_000)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == keys.count)
        #expect(keys.contains(WorldCoverTileKey.containing(latitude: 36.587, longitude: -121.843)!))
        // 150 km is about 1.35° of latitude, so at most 3 rows of 3° tiles cross the box.
        #expect(Set(keys.map(\.southLat)).count <= 3)
    }

    @Test func coveringWrapsAtTheAntimeridian() {
        let keys = WorldCoverTileKey.covering(latitude: 0, longitude: 179.9, radiusMeters: 50_000)
        #expect(keys.contains { $0.westLon == -180 })
        #expect(keys.contains { $0.westLon == 177 })
    }

    @Test func polarCoveringDoesNotExplode() {
        let keys = WorldCoverTileKey.covering(latitude: 89.9, longitude: 0, radiusMeters: 100_000)
        #expect(keys.count <= 120)
        #expect(keys.allSatisfy { $0.southLat <= 81 })
    }
}
