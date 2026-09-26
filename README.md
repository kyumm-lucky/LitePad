# LitePad

macOS 原生轻量文本编辑器骨架：Swift + SwiftUI 外壳 + AppKit `NSTextView` 编辑核心，定位类似 Notepad++ 的 macOS 平替，安装包量级为原生体积（远小于 Electron 方案）。

## 功能现状

- **页内多标签**（Notepad++ 式）：点击切换、单个关闭、"+" 新建；`Cmd+N` 新建、`Cmd+O` 打开、`Cmd+S` 保存、`Cmd+W` 关闭当前标签
- **编辑核心**：`NSTextView`，等宽字体、软换行、系统级撤销/重做、关闭自动引号/破折号替换
- **语法高亮**（正则版，按扩展名自动识别）：HTML / XML / SQL / Java / Python / JavaScript / JSON，其余按纯文本处理
- **行号栏**：随滚动与编辑刷新
- **未保存保护**：关闭有更改的标签时弹窗（保存 / 不保存 / 取消）；标签页与状态栏显示未保存状态
- **打包**：`make app` 一键产出 `.app`（ad-hoc 签名），`make dmg` 产出带拖拽安装链接的 DMG

## 环境要求

- macOS 13+
- Swift 5.9+（Xcode 或 Command Line Tools 均可，本机仅需 `swift build`）

## 快速开始

```bash
make run    # 开发调试（裸进程运行，菜单栏可能不完整，正式体验建议用 .app）
make app    # 构建 build/LitePad.app
open build/LitePad.app
make dmg    # 构建 build/LitePad-0.1.0.dmg
make clean
```

## 目录结构

```
LitePad/
├── Package.swift                  # SwiftPM 工程描述（无第三方依赖）
├── Sources/LitePad/
│   ├── LitePadApp.swift           # @main 入口、菜单与快捷键
│   ├── Model/
│   │   ├── EditorTab.swift        # 单个标签页的文档状态（文本、文件、语言、脏标记）
│   │   └── EditorSession.swift    # 标签页会话：新建/打开/保存/关闭
│   ├── Editor/
│   │   ├── CodeTextView.swift     # NSTextView 的 NSViewRepresentable 封装
│   │   ├── LanguageDefinition.swift # 各语言的正则规则表
│   │   ├── SyntaxHighlighter.swift  # 全文重刷式高亮（带优先级跳过）
│   │   └── LineNumberRulerView.swift # 行号栏
│   └── Views/
│       ├── ContentView.swift      # 标签栏 + 编辑区 + 状态栏
│       └── TabBarView.swift       # 页内标签栏
├── Resources/Info.plist           # App 包描述（由打包脚本使用）
├── scripts/make-app.sh            # 编译并组装 .app
└── scripts/make-dmg.sh            # 生成 DMG
```

## 设计说明

- **为什么编辑器核心不用 SwiftUI `TextEditor`**：macOS 上它在行号、高亮定制、大文件表现上都不够用；`NSTextView` 免费提供撤销/重做、输入法与文本存储管理，通过 `NSViewRepresentable` 桥接进 SwiftUI。
- **高亮实现**：v1 为"全文重刷 + 规则优先级跳过"的正则方案（注释 > 字符串 > 数字 > 关键词 > 标签），逻辑简单可靠；代价是大文件逐键性能一般。
- **标签切换**：以 `tab.id` 重建编辑视图，避免多标签间的文本与选区串扰。
- **`Cmd+W`**：自定义的"关闭标签页"与系统"关闭窗口"共存在 File 菜单中，如发现快捷键被系统项抢占，可在菜单栏手动确认优先级。

## Roadmap

- [ ] tree-sitter 替换正则高亮（增量解析，精准支持更多语言）
- [ ] 查找/替换（`Cmd+F`）、跳转到行
- [ ] 拖拽文件到窗口打开、外部文件变更监听
- [ ] 编码检测与转换（GBK 等）
- [ ] 大文件优化（可见范围重绘、行号缓存）
- [ ] 自定义主题 / 字体设置、软换行开关
- [ ] App 图标、Developer ID 签名与公证（对外分发需要）

## 修改 App 名称

全局替换三处即可：`Package.swift`（target 名）、`Resources/Info.plist`（CFBundleName 等）、`scripts/` 与 `Makefile` 中的 `LitePad`。
