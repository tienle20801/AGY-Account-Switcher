import Foundation
import XCTest

class TempDirectoryTestCase: XCTestCase {
    var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AGYAutoChangerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Protobuf Test Encoding Helpers

    func encodeVarint(_ value: UInt64) -> Data {
        var data = Data()
        var v = value
        while true {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                byte |= 0x80
            }
            data.append(byte)
            if v == 0 { break }
        }
        return data
    }

    func protoVarintField(_ fieldNumber: Int, _ value: UInt64) -> Data {
        var data = encodeVarint(UInt64(fieldNumber << 3))
        data.append(encodeVarint(value))
        return data
    }

    func protoLengthField(_ fieldNumber: Int, _ payload: Data) -> Data {
        var data = encodeVarint(UInt64((fieldNumber << 3) | 2))
        data.append(encodeVarint(UInt64(payload.count)))
        data.append(payload)
        return data
    }
}
