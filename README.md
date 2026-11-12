# swift-asar

Pure Swift reader and writer for [Electron](https://www.electronjs.org)'s `asar` archive format.
No Node.js, no C dependencies — just Foundation.

Electron 的 `asar` 归档纯 Swift 实现，可读取、解包、重新打包。不依赖 Node.js 或任何 C 库。

## 为什么还要一个

Node 生态里有 `@electron/asar`，但如果你想写的是 **macOS 原生工具**（SwiftUI 应用、命令行工具、菜单栏 App），
为了读一个归档而引入 Node 运行时并不划算。

这个库把 asar 格式的读写压缩到约 350 行 Swift，没有依赖：

- 读取：解析头部，按 `offset` / `size` 直接切片
- 解包：完整导出目录树，含符号链接与 `unpacked` 文件
- 打包：确定性遍历顺序、重新计算全部偏移、处理 `unpacked` 分离
- 单文件读取：不解包整个归档也能取其中一个文件

## 安装

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/shizhen-ting/swift-asar", from: "1.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "Asar", package: "swift-asar")])
]
```

## 用法

### 列出内容

```swift
import Asar

let entries = try Asar.entries(at: asarURL)
for entry in entries where !entry.isDirectory {
    print(entry.path, entry.size, entry.unpacked ? "(unpacked)" : "")
}
```

### 解包

```swift
let count = try Asar.extract(asarURL, to: outputDirectory)
print("导出了 \(count) 个文件")
```

`unpacked` 文件会从 `<asar>.unpacked/` 目录恢复，符号链接按原样重建。

### 读单个文件

```swift
let data = try Asar.data(for: "package.json", in: asarURL)
let info = try JSONSerialization.jsonObject(with: data) as? [String: Any]
```

### 打包

```swift
try Asar.pack(directory: appDirectory,
              to: outputURL,
              unpacked: ["bin", "node_modules/native-module"])
```

`unpacked` 传入的是路径前缀，命中的文件会写到 `<asar>.unpacked/` 下，而不是塞进归档。

## API

| 方法 | 说明 |
| --- | --- |
| `Asar.entries(at:)` | 列出所有条目（含目录与链接），按路径排序 |
| `Asar.entry(at:in:)` | 查找单个条目 |
| `Asar.data(for:in:)` | 读取单个文件内容 |
| `Asar.extract(_:to:)` | 完整解包，返回导出文件数 |
| `Asar.pack(directory:to:unpacked:)` | 打包目录 |

`AsarEntry` 字段：`path`、`size`、`offset`、`unpacked`、`link`、`isDirectory`。

## 格式要点

```
[uint32 = 4][uint32 头部尺寸][头部]
头部 = [uint32 payloadLen][uint32 jsonLen][JSON][64 字节对齐填充]
文件数据起点 = 8 + 头部尺寸
```

- JSON 里每个文件节点的 `offset` 相对于**文件数据起点**，不是文件开头
- `offset` 在不同实现里既可能是字符串也可能是数字，本库两种都接受
- 重新打包时所有偏移必须按写入顺序重算，否则内容会错位
- `unpacked: true` 的节点不在归档体内，实际文件在 `<asar>.unpacked/` 下

## 测试

```bash
swift run verify
```

不依赖 XCTest，在只有命令行工具的机器上也能跑。会用临时目录做「打包 → 解析 → 解包」往返校验，
覆盖嵌套目录、空目录、符号链接、`unpacked` 文件、截断文件与数字/字符串两种 `offset` 写法。

要针对真实归档验证：

```bash
ASAR_SAMPLE=/path/to/Electron.app/Contents/Resources/app.asar swift run verify
```

已验证：Screen Studio 4.1.0 的 248 MB 归档，4607 个条目全部解析正确，2.8 MB 的大文件字节数一致。

仓库里另有 `Tests/AsarTests/`，基于 XCTest，供装有完整 Xcode 的环境执行 `swift test`。

## License

MIT
