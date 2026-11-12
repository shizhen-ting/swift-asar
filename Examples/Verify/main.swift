//
//  verify/main.swift
//  不依赖 XCTest 的自检程序：在没有 Xcode、只有命令行工具的环境也能验证库是否正确。
//  用法：swift run verify
//

import Foundation
import Asar

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: String) {
    checks += 1
    if condition {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message)")
    }
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("asar-verify-\(UUID().uuidString)")
try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: sandbox) }

// ---------------------------------------------------------------- 场景 1：往返
print("场景 1 · 打包 → 解析 → 解包往返")
do {
    let source = sandbox.appendingPathComponent("src")
    try fm.createDirectory(at: source.appendingPathComponent("nested/deep"), withIntermediateDirectories: true)
    try fm.createDirectory(at: source.appendingPathComponent("emptydir"), withIntermediateDirectories: true)
    try Data("hello world".utf8).write(to: source.appendingPathComponent("a.txt"))
    try Data(repeating: 0xAB, count: 100_000).write(to: source.appendingPathComponent("nested/big.bin"))
    try Data("中文内容".utf8).write(to: source.appendingPathComponent("nested/deep/c.txt"))
    try fm.createSymbolicLink(atPath: source.appendingPathComponent("link.txt").path,
                              withDestinationPath: "a.txt")

    let archive = sandbox.appendingPathComponent("app.asar")
    try Asar.pack(directory: source, to: archive)
    check(fm.fileExists(atPath: archive.path), "生成 asar 文件")

    let entries = try Asar.entries(at: archive)
    let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
    check(byPath["a.txt"]?.size == 11, "条目尺寸正确")
    check(byPath["nested/big.bin"]?.size == 100_000, "嵌套文件尺寸正确")
    check(byPath["emptydir"]?.isDirectory == true, "空目录被记录")
    check(byPath["link.txt"]?.link == "a.txt", "符号链接被记录")

    let output = sandbox.appendingPathComponent("out")
    try Asar.extract(archive, to: output)
    check(try String(contentsOf: output.appendingPathComponent("a.txt"), encoding: .utf8) == "hello world",
          "文本内容一致")
    check(try Data(contentsOf: output.appendingPathComponent("nested/big.bin")).count == 100_000,
          "二进制内容一致")
    check(try String(contentsOf: output.appendingPathComponent("nested/deep/c.txt"), encoding: .utf8) == "中文内容",
          "嵌套中文内容一致")
    check(fm.fileExists(atPath: output.appendingPathComponent("emptydir").path), "空目录被还原")
    check((try? fm.destinationOfSymbolicLink(atPath: output.appendingPathComponent("link.txt").path)) == "a.txt",
          "符号链接被还原")
}

// ---------------------------------------------------------------- 场景 2：unpacked
print("场景 2 · unpacked 文件分离")
do {
    let source = sandbox.appendingPathComponent("src2")
    try fm.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: source.appendingPathComponent("bin/tool"))
    try Data("x".utf8).write(to: source.appendingPathComponent("readme.txt"))

    let archive = sandbox.appendingPathComponent("app2.asar")
    try Asar.pack(directory: source, to: archive, unpacked: ["bin"])

    check(fm.fileExists(atPath: archive.path + ".unpacked/bin/tool"), "unpacked 文件被单独写出")
    let entries = try Asar.entries(at: archive)
    check(entries.first { $0.path == "bin/tool" }?.unpacked == true, "条目标记为 unpacked")

    let output = sandbox.appendingPathComponent("out2")
    try Asar.extract(archive, to: output)
    check(fm.fileExists(atPath: output.appendingPathComponent("bin/tool").path), "解包时从 unpacked 目录恢复")
}

// ---------------------------------------------------------------- 场景 3：异常输入
print("场景 3 · 异常输入")
do {
    let bad = sandbox.appendingPathComponent("bad.asar")
    try Data(repeating: 0, count: 3).write(to: bad)
    check((try? Asar.entries(at: bad)) == nil, "截断文件应报错")
    check((try? Asar.extract(bad, to: sandbox.appendingPathComponent("x"))) == nil, "截断文件解包应报错")
    check((try? Asar.entries(at: sandbox.appendingPathComponent("nope.asar"))) == nil, "不存在的文件应报错")
}

// ---------------------------------------------------------------- 场景 4：offset 数字形式
print("场景 4 · offset 为数字的归档（兼容性）")
do {
    let payload = Data("XYZ".utf8)
    let tree: [String: Any] = ["files": ["f.txt": ["size": 3, "offset": 0]]]
    let json = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])

    var payloadBlock = Data()
    var jsonLen = UInt32(json.count).littleEndian
    payloadBlock.append(Data(bytes: &jsonLen, count: 4))
    payloadBlock.append(json)
    let aligned = ((payloadBlock.count + 63) / 64) * 64
    payloadBlock.append(Data(repeating: 0, count: aligned - payloadBlock.count))

    var header = Data()
    var headerLen = UInt32(payloadBlock.count).littleEndian
    header.append(Data(bytes: &headerLen, count: 4))
    header.append(payloadBlock)

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
    check(entries.first { $0.path == "f.txt" }?.offset == 0, "数字 offset 被正确解析")

    let output = sandbox.appendingPathComponent("numeric-out")
    try Asar.extract(archive, to: output)
    check(try String(contentsOf: output.appendingPathComponent("f.txt"), encoding: .utf8) == "XYZ",
          "数字 offset 的文件内容正确")
}

// ---------------------------------------------------------------- 场景 5：真实归档
// 用法：ASAR_SAMPLE=/path/to/app.asar swift run verify
if let sample = ProcessInfo.processInfo.environment["ASAR_SAMPLE"] {
    print("场景 5 · 真实归档（\(URL(fileURLWithPath: sample).lastPathComponent)）")
    if fm.fileExists(atPath: sample) {
        let url = URL(fileURLWithPath: sample)
        let entries = try Asar.entries(at: url)
        check(entries.count > 100, "解析出 \(entries.count) 个条目")

        if let pkg = try? Asar.data(for: "package.json", in: url),
           let obj = (try? JSONSerialization.jsonObject(with: pkg)) as? [String: Any] {
            check(true, "读取 package.json（name = \(obj["name"] ?? "?"))")
        } else {
            check(false, "读取 package.json")
        }

        let big = entries.filter { !$0.isDirectory && !$0.unpacked && $0.size > 1_000_000 }
        check(big.count > 0, "存在 \(big.count) 个大文件（>1MB），offset 计算可验证")
        if let first = big.first, let data = try? Asar.data(for: first.path, in: url) {
            check(data.count == first.size, "大文件尺寸匹配：\(first.path) = \(data.count) 字节")
        }
    } else {
        print("  跳过：文件不存在")
    }
}

// ---------------------------------------------------------------- 汇总
print("")
if failures == 0 {
    print("全部通过（\(checks) 项检查）")
    exit(0)
} else {
    print("失败 \(failures) / \(checks) 项")
    exit(1)
}
