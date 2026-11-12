# PowerFlow

macOS 菜单栏功耗走向工具：**趋势优先**，插电时以系统负载为主数字，充电功率作副标，
并且把「未归因的残差」如实画出来。

数据全部本机只读采集，不写 SMC、不装 helper、不需要 sudo 或辅助功能授权，也不联网。

## 一眼看懂

```
实测系统负载 P_system
  = Σ 已归因 App（rusage v6 真实能量）
  + 屏幕背光（SMC PDBR）
  + USB-C 接口（SMC D1–D4）
  + 残差（无线 / SSD / 风扇 / 内核 / DC-DC 损耗）
```

残差不藏，画成灰色堆叠带；同时给出**归因覆盖率** `Σ App / (P_system − 屏幕 − 接口)`，
让「某个 App 耗 3W」这句话有可验证的锚点。

## 构建与运行

```sh
./build.command                  # release 构建，产出 build/PowerFlow.app
CONFIG=debug ./build.command     # 需要断点/日志时用 debug
open build/PowerFlow.app
```

要求 macOS 14+、Swift 6 工具链。零第三方依赖，纯 SPM，不生成 Xcode 工程。

编译完成后直接跑二进制也可以，方便看日志：

```sh
./build/PowerFlow.app/Contents/MacOS/PowerFlow --show-panel --debug-size
```

## 使用

- 点菜单栏 `⚡ 36.8`：展开面板（状态、系统负载、流向图、Top App、趋势入口）
- 右键菜单栏图标：打开趋势窗口 / 打开面板 / 退出
- 趋势窗口：系统负载分解堆叠图（含灰色残差带）+ 实测总量线 + 电池功率副图 + App 排行

调试开关：

| 参数 | 作用 |
| --- | --- |
| `--show-panel` | 启动后自动弹面板（便于无人值守截图校验） |
| `--show-window` | 启动后自动打开趋势窗口 |
| `--debug-size` | 打印面板尺寸测量与状态项窗口位置（判断图标是否被挤到屏幕外） |
| `--render <dir>` | 不进 UI，直接把面板与趋势图渲染成 PNG（布局回归用） |

## 命令行诊断

`powerflow-probe` 不开 UI，用来和活动监视器 / `powermetrics` 对账：

```sh
swift build --product powerflow-probe
PROBE=$(swift build --product powerflow-probe --show-bin-path)/powerflow-probe

$PROBE                 # 连续 3 轮功率
$PROBE --rounds 10     # 连续 10 轮
$PROBE --dump          # 打印 SMC 原始键的类型与字节
$PROBE --battery       # 打印 IOPS 电池遥测与原始 PowerTelemetryData
$PROBE --energy        # 打印进程能量归因
```

## 目录结构

```
Sources/PowerFlowCore/
  Model/PowerSample.swift      采样模型、残差与覆盖率的唯一定义
  PowerSampler.swift           2s 节拍、历史环形缓冲
  Probe/SMC.swift              只读 SMC 客户端（80 字节 KeyData、小端载荷）
  Probe/BatteryTelemetry.swift IOPS AppleSmartBattery 遥测
  Probe/PowerResolver.swift    SMC 优先、遥测兜底、充电功率预算收敛
  Probe/EnergyProbe.swift      proc_pid_rusage(RUSAGE_INFO_V6)
  Probe/ProcessResolver.swift  进程 → 最外层 .app 归并
  Probe/PortProbe.swift        USB-C 口功率
  Store/                       SQLite 分层存储与降采样
Sources/PowerFlow/
  App/                         NSStatusItem + NSPopover + 趋势窗口
  UI/                          PanelView / FlowDiagram / TrendChart / Theme
Sources/PowerFlowProbe/        终端诊断入口
Tests/PowerFlowCoreTests/      17 个单元测试
```

## 为什么不用 `MenuBarExtra`

SwiftUI 的 `MenuBarExtra` 在 SPM 产出的 .app bundle 里、没有可见窗口时会在启动阶段直接结束进程，
`LSUIElement` 也救不回来。所以入口用 AppKit 手动搭 `NSStatusItem` + `NSPopover`，
视图仍然是 SwiftUI（`NSHostingController`）。

## 已知局限（不是 bug，是边界）

- `rusage` 是 SoC 侧能量记账，**不含屏幕背光与无线**，所以残差必然存在；覆盖率典型落在 10–80%，取决于负载类型
- `PDBR` 只是背光功率，不是整块面板耗电
- USB-C 口位（D1–D4）与物理端口的对应关系未在所有机型验证
- SMC 键在不同 Apple Silicon 代际有差异，靠能力探测降级；缺失时对应副标显示 `—`
- 插电瞬间适配器协商会让输入功率跳变，需 2–3 个采样点后才稳定
- 采样间隔 2s，短于 2s 的尖峰会被平均掉
- **菜单栏图标可能被系统藏起来**：macOS 26 在状态区坐满时会把新图标塞到时钟底下（窗口落到屏幕外），
  并把「隐藏」记进偏好，之后即使有空位也不会自己回来。处理办法：
  - 应用启动 3 秒后自检图标位置，发现被塞住就直接打开趋势窗口，不会「启动了却什么都看不到」；
  - 想恢复图标：先退掉几个菜单栏常驻 App，再 `defaults delete io.powerflow.app` 后重启 PowerFlow；
  - 图标可见时面板从图标下方弹出；图标不可用时，趋势窗口承担全部功能。

## 与参考项目的差异

| 项目 | 整机实测 | App 归因 | 能对账 |
| --- | --- | --- | --- |
| kinghhhin-design/power | 有（SMC） | 无 | — |
| wwek/power-lens | 无 | CPU% 打分（非能量） | — |
| luke-fairbanks/BatteryHog | 部分（powermetrics） | 有 | 无 |
| MUU3327/BatteryHarbor | 有 | 有（rusage） | 无 |
| **PowerFlow** | 有（SMC，实时） | 有（rusage v6） | **有（预算闭合 + 残差 + 覆盖率）** |
