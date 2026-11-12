import XCTest
@testable import Asar

final class AsarTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("asar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    // MARK: - 辅助

    private func makeSourceTree() throws -> URL {
        let root = sandbox.appendingPathComponent("src")
        let fm = FileManager.default

        try fm.createDirectory(at: root.appendingPathComponent("nested/deep"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("emptydir"),
                               withIntermediateDirectories: true)

        try Data("hello world".utf8).write(to: root.appendingPathComponent("a.txt"))
        let big = Data(repeating: 0xAB, count: 100_000)
        try big.write(to: root.appendingPathComponent("nested/big.bin"))
        try Data("中文内容".utf8).write(to: root.appendingPathComponent("nested/deep/c.txt"))

        // 符号链接
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path,
                                  withDestinationPath: "a.txt")

        return root
    }

    // MARK: - 往返

    func testPackAndExtractRoundTrip() throws {
        let source = try makeSourceTree()
        let archive = sandbox.appendingPathComponent("app.asar")

        try Asar.pack(directory: source, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let entries = try Asar.entries(at: archive)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })

        XCTAssertNotNil(byPath["a.txt"])
        XCTAssertEqual(byPath["a.txt"]?.size, 11)
        XCTAssertEqual(byPath["nested/big.bin"]?.size, 100_000)
        XCTAssertEqual(byPath["emptydir"]?.isDirectory, true)
        XCTAssertEqual(byPath["link.txt"]?.link, "a.txt")

        let output = sandbox.appendingPathComponent("out")
        let count = try Asar.extract(archive, to: output)
        XCTAssertGreaterThan(count, 0)

        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("a.txt"), encoding: .utf8),
                       "hello world")
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("nested/big.bin")).count,
                       100_000)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("nested/deep/c.txt"),
                                  encoding: .utf8),
                       "中文内容")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("emptydir").path))

        // 符号链接应被还原
        let linkTarget = try fm.destinationOfSymbolicLink(
            atPath: output.appendingPathComponent("link.txt").path)
        XCTAssertEqual(linkTarget, "a.txt")
    }

    // MARK: - unpacked

    func testUnpackedFilesAreSeparated() throws {
        let source = try makeSourceTree()
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: source.appendingPathComponent("bin/tool"))

        let archive = sandbox.appendingPathComponent("app.asar")
        try Asar.pack(directory: source, to: archive, unpacked: ["bin"])

        let unpackedCopy = archive.path + ".unpacked/bin/tool"
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpackedCopy))

        let entries = try Asar.entries(at: archive)
        let tool = entries.first { $0.path == "bin/tool" }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.unpacked, true)

        let output = sandbox.appendingPathComponent("out2")
        try Asar.extract(archive, to: output)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("bin/tool").path))
    }

    // MARK: - 异常输入

    func testMalformedArchiveThrows() throws {
        let bad = sandbox.appendingPathComponent("bad.asar")
        try Data(repeating: 0, count: 3).write(to: bad)

        XCTAssertThrowsError(try Asar.entries(at: bad))
        XCTAssertThrowsError(try Asar.extract(bad, to: sandbox.appendingPathComponent("x")))
    }

    func testMissingArchiveThrows() {
        let missing = sandbox.appendingPathComponent("nope.asar")
        XCTAssertThrowsError(try Asar.entries(at: missing))
    }

    // MARK: - 偏移兼容性

    func testNumericOffsetIsAccepted() throws {
        // 手工构造一个 offset 为数字的归档，验证两种写法都能解
        let payload = Data("XYZ".utf8)
        let tree: [String: Any] = [
            "files": [
                "f.txt": ["size": 3, "offset": 0]   // 数字，而非字符串
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])

        var body = Data()
        body.append(contentsOf: [0, 0, 0, 0])                 // 前置 4 字节
        var payloadWithLen = Data()
        payloadWithLen.append(contentsOf: [UInt8(json.count & 0xFF)])
        payloadWithLen.append(contentsOf: [0, 0, 0])          // 小端 JSON 长度（此处仅验证小尺寸）
        payloadWithLen.append(json)
        let aligned = ((payloadWithLen.count + 63) / 64) * 64
        payloadWithLen.append(Data(repeating: 0, count: aligned - payloadWithLen.count))

        var header = Data()
        var headerLen = UInt32(payloadWithLen.count).littleEndian
        header.append(Data(bytes: &headerLen, count: 4))
        header.append(payloadWithLen)

        var file = Data()
        var four = UInt32(4).littleEndian
        file.append(Data(bytes: &four, count: 4))
        var hl = UInt32(header.count).littleEndian
        file.append(Data(bytes: &hl, count: 4))
        file.append(header)
        file.append(payload)

        let archive = sandbox.appendingPathComponent("numeric.asar")
        try file.write(to: archive)

        let entries = try Asar.entries(at: archive)
        XCTAssertEqual(entries.first { $0.path == "f.txt" }?.offset, 0)

        let output = sandbox.appendingPathComponent("numeric-out")
        try Asar.extract(archive, to: output)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("f.txt"),
                                  encoding: .utf8), "XYZ")
    }
}
