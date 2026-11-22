import Testing
import Foundation
@testable import SFPerf

@Suite struct MemoryBudgetTests {
    @Test func ceilingsFollowSection11() {
        let gib = 1_073_741_824
        #expect(MemoryBudget.forDevice(.phone, physicalMemory: 6 * gib).ceiling == Int(1.5 * Double(gib)))
        #expect(MemoryBudget.forDevice(.phone, physicalMemory: 4 * gib).ceiling == gib)
        #expect(MemoryBudget.forDevice(.tablet, physicalMemory: 16 * gib).ceiling == Int(2.5 * Double(gib)))
        #expect(MemoryBudget.forDevice(.mac, physicalMemory: 32 * gib).ceiling == 4 * gib)
    }

    @Test func cacheHalvesOnWarningAndRespectsOSHeadroom() {
        let b = MemoryBudget(ceiling: 1_000 * MemoryBudget.mebibyte)
        let normal = b.cacheLimit(.imagery, pressure: .normal, currentlyResident: 0, osAvailable: nil)
        let warn = b.cacheLimit(.imagery, pressure: .warning, currentlyResident: 0, osAvailable: nil)
        #expect(abs(warn * 2 - normal) <= 1)
        // OS has only 450 MB free and we keep 400 MB: cache may grow by 50 MB over what it holds.
        let tight = b.cacheLimit(.imagery, pressure: .normal, currentlyResident: 100 * MemoryBudget.mebibyte,
                                 osAvailable: 450 * MemoryBudget.mebibyte)
        #expect(tight == 150 * MemoryBudget.mebibyte)
    }

    @Test func ledgerFlagsOverBudgetCategory() {
        let b = MemoryBudget(ceiling: 1_000)
        var l = MemoryLedger()
        l.add(300, to: .imagery)
        #expect(!l.isOver(b))
        l.add(100, to: .imagery)   // 400 > 35 % of 1000
        #expect(l.isOver(b))
        l.remove(500, from: .imagery)
        #expect(l.bytes(.imagery) == 0)
    }
}

@Suite struct ASTCTests {
    @Test func blockSizes() {
        #expect(ASTCBlock.b4x4.byteSize(width: 256, height: 256) == 64 * 64 * 16)
        #expect(ASTCBlock.b8x8.byteSize(width: 256, height: 256) == 32 * 32 * 16)
        #expect(ASTCBlock.b6x6.byteSize(width: 10, height: 10) == 2 * 2 * 16)   // partial blocks round up
        #expect(ASTCBlock.b4x4.bitsPerPixel == 8)
        #expect(ASTCBlock.b8x8.bitsPerPixel == 2)
        #expect(ASTCBlock.b4x4.bytesPerRow(width: 10) == 3 * 16)
    }

    @Test func chainDropsTopMip() {
        let full = ASTCBlock.b4x4.chainByteSize(width: 64, height: 64)
        let skip = ASTCBlock.b4x4.chainByteSize(width: 64, height: 64, firstMip: 1)
        #expect(full - skip == ASTCBlock.b4x4.byteSize(width: 64, height: 64))
    }
}

@Suite struct StreamingTests {
    @Test func plannerFitsBudgetAndKeepsBigTilesSharp() {
        let tiles = (0..<8).map { i in
            StreamedTile(id: UInt64(i), width: 1_024, height: 1_024, block: .b6x6, screenPixels: i == 0 ? 1_024 : 64)
        }
        let full = tiles.reduce(0) { $0 + $1.block.chainByteSize(width: 1_024, height: 1_024) }
        let budget = full / 4
        let first = StreamingPlanner.firstMips(tiles, budget: budget)
        let used = tiles.reduce(0) { $0 + $1.block.chainByteSize(width: 1_024, height: 1_024, firstMip: first[$1.id] ?? 0) }
        #expect(used <= budget)
        #expect(first[0] == 0)                        // the on-screen-large tile stays at full resolution
        #expect(first[7]! > first[0]!)
    }

    @Test func lruEvictsOldestButNeverThisFrame() {
        var c = ResidencyCache(budget: 300)
        c.beginFrame(); c.insert(1, bytes: 100)
        c.beginFrame(); c.insert(2, bytes: 100)
        c.beginFrame(); c.insert(3, bytes: 100)
        c.beginFrame()
        c.touch(1)
        let evicted = c.insert(4, bytes: 100)
        #expect(evicted == [2])
        #expect(c.contains(1) && c.contains(3) && c.contains(4))
        let shrunk = c.setBudget(100)   // memory warning: 1, 3 and 4 are older than 4 (this frame)
        #expect(!shrunk.contains(4) && c.resident <= 200)
    }

    @Test func schedulerHonoursPriorityAndCap() {
        var s = LoadScheduler(maxInFlight: 2)
        s.want([.init(id: 1, priority: 1), .init(id: 2, priority: 9), .init(id: 3, priority: 5)])
        #expect(s.next() == [2, 3])
        #expect(s.next().isEmpty)
        s.finished(2)
        s.want([.init(id: 1, priority: 1), .init(id: 7, priority: 8)])   // 3 still loading; id 7 outranks 1
        #expect(s.next() == [7])
        #expect(s.pending == 1)
    }
}

@Suite struct GovernorTests {
    private func run(_ g: inout QualityGovernor, ms: Double, seconds: Int, from t0: Double, thermal: ThermalLevel = .nominal) -> [Double] {
        var changes: [Double] = []
        for i in 0..<(seconds * 60) {
            let now = t0 + Double(i) / 60
            if g.update(GovernorSample(gpuMS: ms, cpuMS: 4, thermal: thermal), now: now) != nil { changes.append(now) }
        }
        return changes
    }

    @Test func overBudgetStepsDownNoFasterThanHold() {
        var g = QualityGovernor(tier: .high)
        let changes = run(&g, ms: 25, seconds: 30, from: 0)
        #expect(g.level > 0)
        for (a, b) in zip(changes, changes.dropFirst()) { #expect(b - a >= 3) }
    }

    @Test func stableWhenWithinBudget() {
        var g = QualityGovernor(tier: .medium)
        #expect(run(&g, ms: 14, seconds: 30, from: 0).isEmpty)
    }

    @Test func recoversSlowlyAndStopsAtTierBaseline() {
        var g = QualityGovernor(tier: .low)
        _ = run(&g, ms: 25, seconds: 20, from: 0)
        let low = g.level
        #expect(low > QualityLadder.startLevel(.low))
        _ = run(&g, ms: 6, seconds: 120, from: 20)
        #expect(g.level == QualityLadder.startLevel(.low))
    }

    @Test func thermalSeriousForcesFloorAndLowPowerCapsFrames() {
        var g = QualityGovernor(tier: .ultra)
        let p = g.update(GovernorSample(gpuMS: 5, cpuMS: 5, thermal: .serious), now: 0)
        #expect(g.level == QualityLadder.thermalFloor(.serious))
        #expect(p != nil)
        var lp = QualityGovernor(tier: .ultra)
        _ = lp.update(GovernorSample(gpuMS: 5, cpuMS: 5, lowPowerMode: true), now: 0)
        #expect(lp.level >= 3)
    }

    @Test func ladderIsMonotonicallyCheaper() {
        let p = QualityLadder.plans
        for (a, b) in zip(p, p.dropFirst()) {
            #expect(b.renderScale <= a.renderScale)
            #expect(b.vegetationDensity <= a.vegetationDensity)
            #expect(b.cloudStepScale <= a.cloudStepScale)
            #expect(b.terrainSSEScale >= a.terrainSSEScale)
        }
        #expect(abs(QualityPlan.full.blended(to: p[3], t: 0.5).renderScale - 0.85) < 1e-9)
    }
}

@Suite struct PacingTests {
    @Test func refreshPolicy() {
        #expect(RefreshPolicy.targetFPS(maxFPS: 120, platform: .phone, thermal: .nominal, lowPowerMode: false) == 60)
        #expect(RefreshPolicy.targetFPS(maxFPS: 120, platform: .tablet, thermal: .nominal, lowPowerMode: false) == 120)
        #expect(RefreshPolicy.targetFPS(maxFPS: 120, platform: .tablet, thermal: .fair, lowPowerMode: false) == 60)
        #expect(RefreshPolicy.targetFPS(maxFPS: 60, platform: .phone, thermal: .serious, lowPowerMode: false) == 30)
        #expect(RefreshPolicy.targetFPS(maxFPS: 60, platform: .phone, thermal: .nominal, lowPowerMode: true) == 30)
    }

    @Test func statsPercentilesAndHitches() {
        var s = FrameStats(capacity: 100)
        for _ in 0..<99 { s.record(frameMS: 16, targetMS: 16.67) }
        s.record(frameMS: 40, targetMS: 16.67)   // > 2 × target
        #expect(s.p50 == 16)
        #expect(s.percentile(0.95) == 16)
        #expect(s.percentile(1) == 40)
        #expect(s.hitches == 1)
        #expect(s.hitchesPerMinute > 1)          // 1 hitch in ~1.6 s
        #expect(!s.meetsPacingTarget(targetMS: 16.67))
    }

    @Test func ringOverwritesOldest() {
        var s = FrameStats(capacity: 4)
        for ms in [100.0, 1, 1, 1, 1] { s.record(frameMS: ms, targetMS: 16.67) }
        #expect(s.count == 4 && s.percentile(1) == 1)
    }
}
