import XCTest
@testable import InteractiveNotch

final class SystemAudioSpectrumTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let sampleCount = 4_096

    func testEachFrequencyRangeDrivesItsOwnBar() {
        let representativeFrequencies: [Double] = [35, 80, 180, 420, 1_000, 2_200, 5_500, 14_000]

        for (expectedBand, frequency) in representativeFrequencies.enumerated() {
            let levels = SpectrumAnalyzer.levels(samples: tone(frequency: frequency), sampleRate: sampleRate)
            let strongestBand = levels.indices.max(by: { levels[$0] < levels[$1] })

            XCTAssertEqual(levels.count, 8)
            XCTAssertEqual(strongestBand, expectedBand, "\(frequency) Hz should drive bar \(expectedBand + 1)")
            XCTAssertGreaterThan(levels[expectedBand], 0.5)
        }
    }

    func testSilenceStaysAtVisualFloor() {
        let levels = SpectrumAnalyzer.levels(
            samples: Array(repeating: 0, count: sampleCount),
            sampleRate: sampleRate
        )

        XCTAssertEqual(levels.count, SpectrumAnalyzer.bandCount)
        XCTAssertTrue(levels.allSatisfy { $0 == 0.04 })
    }

    func testPermissionFailuresAreNotTransient() {
        XCTAssertTrue(AudioSpectrumStatus.failed(OSStatus(bitPattern: 0x7065_726d)).isPermissionFailure)
        XCTAssertTrue(AudioSpectrumStatus.failed(OSStatus(bitPattern: 0x6465_6e79)).isPermissionFailure)
        XCTAssertTrue(AudioSpectrumStatus.failed(-54).isPermissionFailure)
        XCTAssertFalse(AudioSpectrumStatus.failed(-1).isPermissionFailure)
    }

    private func tone(frequency: Double) -> [Float] {
        (0..<sampleCount).map { index in
            Float(0.8 * sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
    }
}
