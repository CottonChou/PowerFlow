import XCTest
@testable import PowerFlowCore

final class PowerSampleTests: XCTestCase {

    private func makeSample(
        system: Double? = 20,
        battery: Double? = nil,
        display: Double? = 3,
        ports: Double? = 0,
        apps: [AppUsage] = []
    ) -> PowerSample {
        PowerSample(
            ts: Date(), onAC: true, charging: false,
            batteryPercent: 80, batteryMinutes: 200,
            pInput: 25, pSystem: system, pBattery: battery,
            pDisplay: display, pPorts: ports, apps: apps
        )
    }

    func testResidualClosesBudget() {
        let apps = [
            AppUsage(key: "a", name: "A", watts: 6, estimated: false, processCount: 1),
            AppUsage(key: "b", name: "B", watts: 4, estimated: false, processCount: 2)
        ]
        let sample = makeSample(system: 20, display: 3, ports: 1, apps: apps)
        XCTAssertEqual(sample.attributed, 10, accuracy: 0.001)
        XCTAssertEqual(sample.residual ?? -1, 6, accuracy: 0.001)
    }

    func testResidualNeverNegative() {
        let apps = [AppUsage(key: "a", name: "A", watts: 50, estimated: false, processCount: 1)]
        let sample = makeSample(system: 20, display: 3, ports: 0, apps: apps)
        XCTAssertEqual(sample.residual, 0)
    }

    func testCoverageUsesAttributableDenominator() {
        let apps = [AppUsage(key: "a", name: "A", watts: 8, estimated: false, processCount: 1)]
        // 分母 = 20 - 3 - 1 = 16
        let sample = makeSample(system: 20, display: 3, ports: 1, apps: apps)
        XCTAssertEqual(sample.coverage ?? -1, 0.5, accuracy: 0.001)
    }

    func testChargeAndDischargeAreMutuallyExclusive() {
        XCTAssertNotNil(makeSample(battery: 12).chargePower)
        XCTAssertNil(makeSample(battery: 12).dischargePower)
        XCTAssertNotNil(makeSample(battery: -12).dischargePower)
        XCTAssertNil(makeSample(battery: -12).chargePower)
        XCTAssertNil(makeSample(battery: 0.01).chargePower)
    }
}

final class DownsamplerTests: XCTestCase {

    private func sample(_ offset: TimeInterval, system: Double, apps: [AppUsage] = []) -> PowerSample {
        PowerSample(
            ts: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            onAC: true, charging: false, batteryPercent: 50, batteryMinutes: nil,
            pInput: 10, pSystem: system, pBattery: nil, pDisplay: 2, pPorts: 0, apps: apps
        )
    }

    func testAverageMergesAppsAndScalars() {
        let samples = [
            sample(0, system: 10, apps: [AppUsage(key: "a", name: "A", watts: 4, estimated: false, processCount: 1)]),
            sample(2, system: 20, apps: [AppUsage(key: "a", name: "A", watts: 6, estimated: false, processCount: 1)])
        ]
        let averaged = Downsampler.average(samples)
        XCTAssertEqual(averaged?.pSystem ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(averaged?.apps.first?.watts ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(averaged?.apps.first?.processCount, 1)
    }

    func testAverageHandlesMissingValues() {
        var first = sample(0, system: 10)
        first = PowerSample(ts: first.ts, onAC: true, charging: false, batteryPercent: 50,
                            batteryMinutes: nil, pInput: nil, pSystem: 10, pBattery: nil,
                            pDisplay: nil, pPorts: nil, apps: [])
        let second = sample(2, system: 20)
        let averaged = Downsampler.average([first, second])
        XCTAssertEqual(averaged?.pDisplay ?? -1, 2, accuracy: 0.001)
        // 只有第二个样本报告了接口功率，均值只对非空值求平均。
        XCTAssertEqual(averaged?.pPorts ?? -1, 0, accuracy: 0.001)
    }

    func testDecimateKeepsBoundaries() {
        let samples = (0..<100).map { sample(Double($0), system: Double($0)) }
        let decimated = Downsampler.decimate(samples, to: 10)
        XCTAssertLessThanOrEqual(decimated.count, 11)
        XCTAssertEqual(decimated.last?.ts, samples.last?.ts)
    }

    func testDecimateIsIdentityWhenUnderLimit() {
        let samples = (0..<5).map { sample(Double($0), system: 1) }
        XCTAssertEqual(Downsampler.decimate(samples, to: 10).count, 5)
    }
}

final class ProcessResolverTests: XCTestCase {

    func testChromeHelperCollapsesToHostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let identity = ProcessResolver.identity(fromPath: path)
        XCTAssertEqual(identity?.name, "Google Chrome")
        XCTAssertEqual(identity?.key, "app:/Applications/Google Chrome.app")
    }

    func testPlainBinaryUsesExecutableName() {
        let identity = ProcessResolver.identity(fromPath: "/usr/bin/yes")
        XCTAssertEqual(identity?.name, "yes")
        XCTAssertEqual(identity?.key, "bin:/usr/bin/yes")
    }
}

final class SMCDecodeTests: XCTestCase {

    func testFloat() {
        // 12.5f = 0x41480000，SMC 载荷按小端排列
        let bits = Float(12.5).bitPattern
        let bytes = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                     UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        XCTAssertEqual(SMC.decode(type: "flt ", bytes: bytes) ?? -1, 12.5, accuracy: 0.001)
    }

    func testSignedSp78() {
        // -2.5 * 256 = -640 → 0xFD80，小端存储为 80 FD
        XCTAssertEqual(SMC.decode(type: "sp78", bytes: [0x80, 0xFD]) ?? 0, -2.5, accuracy: 0.001)
    }

    func testSigned16Milliamps() {
        // -3143 mA → 0xF3B9，小端存储为 B9 F3
        XCTAssertEqual(SMC.decode(type: "si16", bytes: [0xB9, 0xF3]) ?? 0, -3143, accuracy: 0.001)
    }

    func testBatteryVoltageMillivolts() {
        // 11.893 V → 11893 mV → 0x2E75，小端存储为 75 2E
        XCTAssertEqual(SMC.decode(type: "ui16", bytes: [0x75, 0x2E]) ?? 0, 11893, accuracy: 0.001)
    }

    func testUnknownTypeReturnsNil() {
        XCTAssertNil(SMC.decode(type: "ch8*", bytes: [1, 2, 3]))
    }
}

final class AppUsageAggregatorTests: XCTestCase {

    private func sample(_ system: Double, apps: [AppUsage]) -> PowerSample {
        PowerSample(ts: Date(), onAC: false, charging: false, batteryPercent: 50,
                    batteryMinutes: nil, pInput: nil, pSystem: system, pBattery: -system,
                    pDisplay: 1, pPorts: 0, apps: apps)
    }

    func testIntermittentAppIsAveragedDown() {
        let samples = [
            sample(10, apps: [AppUsage(key: "a", name: "A", watts: 8, estimated: false, processCount: 1)]),
            sample(10, apps: []),
            sample(10, apps: []),
            sample(10, apps: [])
        ]
        let aggregated = AppUsageAggregator.aggregate(samples)
        XCTAssertEqual(aggregated.first?.watts ?? -1, 2, accuracy: 0.001)
    }

    func testSortingAndLimit() {
        let samples = [
            sample(10, apps: [
                AppUsage(key: "a", name: "A", watts: 1, estimated: false, processCount: 1),
                AppUsage(key: "b", name: "B", watts: 5, estimated: false, processCount: 1),
                AppUsage(key: "c", name: "C", watts: 3, estimated: false, processCount: 1)
            ])
        ]
        let aggregated = AppUsageAggregator.aggregate(samples, limit: 2)
        XCTAssertEqual(aggregated.count, 2)
        XCTAssertEqual(aggregated.map(\.name), ["B", "C"])
    }
}
