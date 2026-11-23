import Foundation
import Testing
@testable import SFReplay

private func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool {
    abs(a - b) <= eps
}

private func approx(_ a: Vec3, _ b: Vec3, _ eps: Double = 1e-9) -> Bool {
    approx(a.x, b.x, eps) && approx(a.y, b.y, eps) && approx(a.z, b.z, eps)
}

private func sample(_ t: Double, x: Double = 0, speed: Double = 50) -> FlightSample {
    FlightSample(time: t, position: Vec3(x, 0, 100), orientation: .identity, airspeed: speed)
}

@Test func vectorCrossAndLength() {
    #expect(Vec3(1, 0, 0).cross(Vec3(0, 1, 0)) == Vec3(0, 0, 1))
    #expect(approx(Vec3(3, 4, 0).length, 5))
    #expect(Vec3.zero.normalized == Vec3.zero)
}

@Test func quaternionRotatesAxisAngle() {
    let q = Quat.axisAngle(Vec3(0, 0, 1), Double.pi / 2)
    #expect(approx(q.rotate(Vec3(1, 0, 0)), Vec3(0, 1, 0)))
}

@Test func slerpHitsEndpointsAndMidpoint() {
    let a = Quat.identity
    let b = Quat.axisAngle(Vec3(0, 0, 1), Double.pi / 2)
    let mid = Quat.slerp(a, b, 0.5)
    #expect(approx(mid.rotate(Vec3(1, 0, 0)), Vec3(cos(Double.pi / 4), sin(Double.pi / 4), 0), 1e-9))
    #expect(approx(Quat.slerp(a, b, 1).rotate(Vec3(1, 0, 0)), Vec3(0, 1, 0)))
}

@Test func recorderRejectsDuplicatesAndRateLimits() {
    var rec = FlightRecorder(capacity: 100, minInterval: 0.5)
    let first = rec.record(sample(0))
    let tooSoon = rec.record(sample(0.25))
    let second = rec.record(sample(0.5))
    let duplicate = rec.record(sample(0.5))
    let third = rec.record(sample(1.0))
    #expect(first && !tooSoon && second && !duplicate && third)
    #expect(rec.samples.count == 3)
}

@Test func recorderCapsMemoryByDroppingOldest() {
    var rec = FlightRecorder(capacity: 3, minInterval: 0)
    for t in 0..<5 {
        rec.record(sample(Double(t)))
    }
    #expect(rec.samples.count == 3)
    #expect(rec.samples.first?.time == 2)
}

@Test func replayInterpolatesAndClamps() throws {
    let replay = try FlightReplay(samples: [sample(0, x: 0), sample(2, x: 20)])
    #expect(approx(replay.sample(at: 1).position.x, 10))
    #expect(approx(replay.sample(at: 5).position.x, 20))
    #expect(approx(replay.sample(at: -1).position.x, 0))
    #expect(approx(replay.duration, 2))
}

@Test func replayRejectsBadInput() {
    #expect(throws: FlightReplayError.tooFewSamples) {
        try FlightReplay(samples: [sample(0)])
    }
    #expect(throws: FlightReplayError.nonMonotonicTime) {
        try FlightReplay(samples: [sample(1), sample(1)])
    }
}

@Test func chaseCameraSitsBehindAndLooksAtAircraft() throws {
    let replay = try FlightReplay(samples: [sample(0), sample(10)])
    let cam = CinematicCamera(mode: .chase(distance: 50, height: 10))
    let pose = cam.pose(at: 0, in: replay)
    #expect(approx(pose.position, Vec3(-50, 0, 110)))
    let forward = pose.orientation.rotate(Vec3(1, 0, 0))
    #expect(approx(forward, Vec3(50, 0, -10).normalized, 1e-9))
}

@Test func towerCameraDoesNotMove() throws {
    let replay = try FlightReplay(samples: [sample(0), sample(10, x: 100)])
    let fixed = Vec3(5, 5, 5)
    let cam = CinematicCamera(mode: .tower(position: fixed))
    #expect(cam.pose(at: 0, in: replay).position == fixed)
    #expect(cam.pose(at: 10, in: replay).position == fixed)
}

@Test func freeCameraMovesForwardAndClampsPitch() {
    var cam = FreeCamera()
    cam.step(FreeCameraInput(forward: 1), dt: 1)
    #expect(approx(cam.position.x, FreeCamera.baseSpeed))
    cam.step(FreeCameraInput(lookPitch: 1_000), dt: 1)
    #expect(cam.pitch <= FreeCamera.maxPitch)
    cam.zoom(by: -1_000)
    #expect(cam.fovDegrees == FreeCamera.fovRange.lowerBound)
}

@Test func depthOfFieldIsZeroAtFocusAndGrowsAway() {
    let dof = DepthOfField(enabled: true, focusDistance: 10, focalLength: 0.05, fNumber: 2.8)
    #expect(dof.circleOfConfusion(objectDistance: 10) == 0)
    #expect(dof.circleOfConfusion(objectDistance: 20) > dof.circleOfConfusion(objectDistance: 15))
    #expect(DepthOfField(enabled: false).circleOfConfusion(objectDistance: 50) == 0)
}

@Test func sunElevationFollowsTheDay() {
    #expect(approx(TimeOfDay.sunElevationDegrees(hour: 12), 90))
    #expect(approx(TimeOfDay.sunElevationDegrees(hour: 0), -90))
    #expect(approx(TimeOfDay.sunElevationDegrees(hour: 6), 0, 1e-9))
    #expect(TimeOfDay.isDaylight(hour: 13))
    #expect(!TimeOfDay.isDaylight(hour: 23))
    #expect(approx(TimeOfDay.wrapHour(-1), 23))
}

@Test func clipPlanProducesEndExclusiveFrameTimes() {
    let plan = ClipExportPlan(startTime: 0, endTime: 2, frameRate: 30)
    let times = plan.frameTimes
    #expect(times.count == 60)
    #expect(approx(times[0], 0))
    #expect(approx(times[59], 59.0 / 30.0))
}
