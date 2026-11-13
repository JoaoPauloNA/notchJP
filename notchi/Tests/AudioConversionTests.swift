import CoreAudio
import XCTest
@testable import notchi

final class AudioConversionTests: XCTestCase {
    /// Exercise the real callback with synthetic PCM, without capturing or playing audio.
    private func render(_ dsp: any AudioProcessing, input: [[Float]], channels: [UInt32], output: [[Float]], outputChannels: [UInt32]) -> [[Float]] {
        let source = AudioBufferList.allocate(maximumBuffers: input.count)
        let destination = AudioBufferList.allocate(maximumBuffers: output.count)
        let sourceData = input.map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        let destinationData = output.map { samples -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            return pointer
        }
        defer {
            for pointer in sourceData + destinationData { pointer.deallocate() }
            source.unsafeMutablePointer.deallocate()
            destination.unsafeMutablePointer.deallocate()
        }
        for index in input.indices {
            source[index] = AudioBuffer(mNumberChannels: channels[index], mDataByteSize: UInt32(input[index].count * 4), mData: sourceData[index])
        }
        for index in output.indices {
            destination[index] = AudioBuffer(mNumberChannels: outputChannels[index], mDataByteSize: UInt32(output[index].count * 4), mData: destinationData[index])
        }
        dsp.render(input: source.unsafePointer, output: destination.unsafeMutablePointer)
        return output.indices.map { Array(UnsafeBufferPointer(start: destinationData[$0], count: output[$0].count)) }
    }

    func testRateConversionAndChannelMappingStayStableAcrossBlocks() throws {
        let converter = try AudioSampleConverter(input: .init(rate: 44100, channels: 1, planar: false), output: .init(rate: 48000, channels: 2, planar: true), gain: 0.5)
        for block in 0..<100 {
            let result = render(converter, input: [[Float](repeating: 99, count: 441), [Float](repeating: 0.8, count: 441)], channels: [1, 1], output: [[Float](repeating: 9, count: 480), [Float](repeating: 9, count: 480)], outputChannels: [1, 1])
            if block == 0 {
                // A band-limited step has startup ringing; measure steady state separately.
                XCTAssertLessThan(converter.takePeak(), 0.45)
            }
            if block > 0 {
                XCTAssertTrue(result.flatMap { $0 }.allSatisfy { abs($0 - 0.4) < 0.001 })
            }
        }
        XCTAssertEqual(converter.takePeak(), 0.4, accuracy: 0.01)
        XCTAssertEqual(converter.takePeak(), 0)
    }
    func testDownmixAndNonFiniteSamples() throws {
        let converter = try AudioSampleConverter(input: .init(rate: 48000, channels: 2, planar: false), output: .init(rate: 44100, channels: 1, planar: false), gain: 1)
        var samples = (0..<480).flatMap { _ in [Float(0.2), Float(0.6)] }
        samples[100] = .nan
        let first = render(converter, input: [samples], channels: [2], output: [[Float](repeating: 0, count: 441)], outputChannels: [1])
        XCTAssertTrue(first[0].allSatisfy(\.isFinite))
        let result = render(converter, input: [(0..<480).flatMap { _ in [Float(0.2), Float(0.6)] }], channels: [2], output: [[Float](repeating: 0, count: 441)], outputChannels: [1])
        XCTAssertTrue(result[0].allSatisfy { abs($0 - 0.4) < 0.001 })
    }
    func testDownsamplingSuppressesOutOfBandSignal() throws {
        let converter = try AudioSampleConverter(input: .init(rate: 192000, channels: 1, planar: false), output: .init(rate: 48000, channels: 1, planar: false), gain: 1)
        var measured: [Float] = []
        for block in 0..<10 {
            let input = (0..<1024).map { Float(sin(2 * Double.pi * 60000 * Double(block * 1024 + $0) / 192000)) }
            let result = render(converter, input: [input], channels: [1], output: [[Float](repeating: 0, count: 256)], outputChannels: [1])
            if block > 0 { measured += result[0] }
        }
        XCTAssertLessThan(measured.map { abs($0) }.max() ?? 1, 0.02)
    }
    func testInvalidFormatsAreRejected() {
        XCTAssertThrowsError(try AudioSampleConverter(input: .init(rate: .nan, channels: 1, planar: false), output: .init(rate: 48000, channels: 1, planar: false), gain: 1))
    }
}
