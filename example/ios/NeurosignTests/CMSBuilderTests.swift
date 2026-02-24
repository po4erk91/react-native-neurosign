import XCTest
@testable import Neurosign

final class CMSBuilderTests: XCTestCase {

    // MARK: - lengthBytes

    func test_lengthBytes_shortForm() {
        // Values 0-127 use single byte
        XCTAssertEqual(CMSBuilder.lengthBytes(0), [0x00])
        XCTAssertEqual(CMSBuilder.lengthBytes(127), [0x7F])
    }

    func test_lengthBytes_twoByteForm() {
        // 128-255: [0x81, value]
        XCTAssertEqual(CMSBuilder.lengthBytes(128), [0x81, 0x80])
        XCTAssertEqual(CMSBuilder.lengthBytes(200), [0x81, 0xC8])
        XCTAssertEqual(CMSBuilder.lengthBytes(255), [0x81, 0xFF])
    }

    func test_lengthBytes_threeByteForm() {
        // 256-65535: [0x82, high, low]
        XCTAssertEqual(CMSBuilder.lengthBytes(256), [0x82, 0x01, 0x00])
        XCTAssertEqual(CMSBuilder.lengthBytes(1000), [0x82, 0x03, 0xE8])
    }

    func test_lengthBytes_fourByteForm() {
        // 65536-16777215: [0x83, b2, b1, b0]
        let result = CMSBuilder.lengthBytes(100_000)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0], 0x83)
    }

    func test_lengthBytes_fiveByteForm() {
        // 16777216+: [0x84, b3, b2, b1, b0]
        let result = CMSBuilder.lengthBytes(20_000_000)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0], 0x84)
    }

    // MARK: - Primitive types

    func test_null() {
        let result = CMSBuilder.null()
        XCTAssertEqual([UInt8](result), [0x05, 0x00])
    }

    func test_oid() {
        let oidBytes: [UInt8] = [0x2A, 0x86, 0x48]
        let result = CMSBuilder.oid(oidBytes)
        let bytes = [UInt8](result)
        XCTAssertEqual(bytes[0], 0x06) // OID tag
        XCTAssertEqual(bytes[1], 0x03) // length
        XCTAssertEqual(Array(bytes[2...]), oidBytes)
    }

    func test_integer_positive() {
        // Value 0x01 — no high-bit padding needed
        let result = CMSBuilder.integer(Data([0x01]))
        XCTAssertEqual([UInt8](result), [0x02, 0x01, 0x01])
    }

    func test_integer_highBitPadding() {
        // Value 0x80 — high bit set, needs leading zero
        let result = CMSBuilder.integer(Data([0x80]))
        XCTAssertEqual([UInt8](result), [0x02, 0x02, 0x00, 0x80])
    }

    func test_octetString() {
        let result = CMSBuilder.octetString(Data([0xDE, 0xAD]))
        XCTAssertEqual([UInt8](result), [0x04, 0x02, 0xDE, 0xAD])
    }

    func test_sequence() {
        let inner = Data([0x01, 0x02])
        let result = CMSBuilder.sequence(inner)
        let bytes = [UInt8](result)
        XCTAssertEqual(bytes[0], 0x30) // SEQUENCE tag
        XCTAssertEqual(bytes[1], 0x02) // length
        XCTAssertEqual(Array(bytes[2...]), [0x01, 0x02])
    }

    func test_set() {
        let inner = Data([0xAA, 0xBB])
        let result = CMSBuilder.set(inner)
        let bytes = [UInt8](result)
        XCTAssertEqual(bytes[0], 0x31) // SET tag
        XCTAssertEqual(bytes[1], 0x02)
    }

    func test_contextTag() {
        let inner = Data([0xFF])
        let tag0 = CMSBuilder.contextTag(0, value: inner)
        let tag1 = CMSBuilder.contextTag(1, value: inner)
        XCTAssertEqual([UInt8](tag0)[0], 0xA0) // [0] CONSTRUCTED
        XCTAssertEqual([UInt8](tag1)[0], 0xA1) // [1] CONSTRUCTED
    }
}
