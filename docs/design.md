# PowerFlow 设计说明（v1，已按 review 结论定稿）

把 `kinghhhin-design/power` 的**整机功率测量与流向 UI**，和 `BatteryHarbor` 的**按 App 真实能耗归因**合成一个程序：
菜单栏常驻，展示电池供电 / 插电供电两种状态下，功耗随时间的走向，并能回答"这段时间的电是谁用的"。

---

## 1. 核心思路：把两个测量层对上账

现有工具的毛病是只做一半：

| 项目 | 有整机总量 | 有 App 归因 | 能对账 |
| --- | --- | --- | --- |
| kinghhhin/power | 有（SMC 实测） | 无 | — |
| BatteryHarbor | 有 | 有（rusage） | 无 |
| BatteryHog | 部分（powermetrics） | 有 | 无 |
| wwek/power-lens | 无 | 假（CPU% 打分） | — |

本项目的关键设计是**闭合的功率预算**：

```
实测系统负载 P_system
  = Σ 已归因 App 功耗 P_app        （rusage v6，实测）
  + 屏幕背光 P_display             （SMC，实测）
  + USB-C 接口 P_ports             （SMC，实测）
  + 残差 R                         （无线/SSD/风扇/内核/DC-DC 损耗）
```

`R` 不藏起来，而是当作正常成分画出来；同时给出**归因覆盖率** `Σ P_app / (P_system − P_display − P_ports)`，
让"某个 App 耗 8W"这句话有个可验证的锚点。这是三个参考项目都没做的事，也是本项目唯一真正的增量。

---

## 2. 数据来源

### 2.1 整机功率层（只读，零提权）

主路径用 IOPS 遥测字典 `AppleSmartBattery` → `PowerTelemetryData`，它天然满足
`SystemPowerIn = SystemLoad + BatteryPower`：

| 字段 | 含义 |
| --- | --- |
| `SystemPowerIn` | 适配器实际输入功率 |
| `SystemLoad` | 系统负载功率 |
| `BatteryPower` | 电池功率，正=充入，负=放出 |
| `AdapterEfficiencyLoss` | 适配器转换损耗 |

回退路径（遥测字典缺失或旧机型）用 SMC 只读键，与 kinghhhin/power 一致：

| SMC 键 | 用途 |
| --- | --- |
| `PDTR` | 适配器输入 W |
| `PSTR` | 系统负载 W |
| `B0AV` × `B0AC` | 电池 V × A（有符号） |
| `PDBR` / `PBwo` / `PBLR` | 屏幕背光 W |
| `D1–D4JV` × `D1–D4JI` | USB-C 各口 V × A |
| `TB0T` | 电池温度 |

两种供电状态的公式：

- **放电（电池供电）**：`P_total = -BatteryPower`
- **插电**：`P_total = SystemPowerIn`，且 `P_total = P_system + P_batt_charge + P_loss`

### 2.2 App 归因层（rusage v6）

沿用 BatteryHarbor 已验证的做法：`proc_pid_rusage(pid, RUSAGE_INFO_V6)` 取 `ri_energy_nj`。
这是内核给每个进程记的真实能量（焦耳），与活动监视器"能耗影响"同源，**不需要 root**。

```
P_app = (E_nj(t) − E_nj(t−Δt)) / 1e9 / Δt     单位 W
```

取不到能量时退化为 `cpu秒 × 10 + wakeup × 0.002 + IO_MB × 0.05`（BatteryHarbor 同款），
并在 UI 上标记该 App 为"估算"而非"实测"，不与实测值混画。

进程聚合：先按 bundle path 归并（Chrome 的十几个 renderer、Electron 的 helper 都归到宿主 App），
再兜底按进程名归并；单个 App 显示进程数。

---

## 3. 界面设计

### 3.1 菜单栏

图标 + 实时数字：`⚡ 12.4W`。点击展开 popover（宽 364，高度随内容实测约 430，深色玻璃）。
右键图标出菜单：打开趋势窗口 / 打开面板 / 退出。

popover 自上而下：

1. **状态行**：充电中 / 放电 / 外接供电 · 电池 76% · 剩余 3h12m
2. **主数字**：系统负载（插电时**不含充电功率**），大字号等宽数字；
   右侧副标依次为充电/放电、输入功率、归因覆盖率
3. **流向图**：保留 kinghhhin 的节点+流带语言，但**流带宽度按实际瓦数比例**（原项目是硬编码固定宽度，这是要修的点）
4. **Top 3 App**：名称 + W（估算值带 `≈`）
5. **底部**：能力摘要 + 「趋势 >」入口

> 迷你 sparkline 未做：面板本身只有 430pt 高，再塞一条 40pt 的曲线会把 Top App 挤出视野。
> 趋势入口一键直达，值当。

### 3.2 主窗口（真正的"走向"）

主图是**堆叠面积 + 实测总量线**，默认 30 分钟窗口：

- 底层堆叠：已归因 App（Top N，其余并入"其他 App"）→ 屏幕 → 接口 → **残差（灰）**
- 顶部白线：实测总功耗
- 插拔电事件处打竖虚线，背景色整体切换（电池=暗绿，插电=暗蓝）
- 鼠标悬停十字线，读该时刻各层数值
- 右上角常驻"归因覆盖率 %"，低于 60% 时变黄并提示该窗口数据可信度低

时间范围：5 分钟 / 30 分钟 / 6 小时 / 24 小时。
副视图：App 能耗排行（实时 / 1h / 24h），点某个 App 在主图里高亮其曲线。

---

## 4. 采样与存储

- 采样节拍 2s：一次 IOPS 读 + 3~4 次 SMC 读 + 全进程 rusage 扫描（约 400–800 个 pid，单次 syscall，2s 一次无压力）
- 分层保留，避免无脑写库：
  - 2s 原始点 → 保留 1 小时
  - 10s 降采样 → 保留 6 小时
  - 60s 降采样 → 保留 7 天
- 存储用系统自带 `libsqlite3`（不引第三方依赖），单表 `samples(ts, p_in, p_system, p_batt, p_display, p_ports, p_residual)`，
  App 明细另表按 10s/60s 粒度存
- 数据库落在 `~/Library/Application Support/PowerFlow/`，提供"清除历史"

---

## 5. 技术选型

- Swift 6 + SwiftUI 视图 + **AppKit 壳**（`NSStatusItem` + `NSPopover`），不用 `MenuBarExtra`
- 最低 macOS 14，Apple Silicon 优先；Intel 只保证不崩、显示"—"
- **SPM executable + build 脚本产出 .app**，不做 Xcode 工程 —— 便于 review，也避免签名配置的坑
- 零第三方依赖
- **零权限**：不写 SMC、不装 helper、不要 sudo、不要辅助功能授权。这是相对 BatteryHarbor / BatteryHog 最实际的改进

为什么不用 `MenuBarExtra`：在 SPM 产出的 .app bundle 里，没有可见窗口时它会在启动阶段直接结束进程
（`LSUIElement` 也会触发）。这个结论是实测出来的，不是猜的。

---

## 6. 目录结构

```
Sources/PowerFlowCore/       采样与归因（不依赖 AppKit，可单测、可被 CLI 复用）
  Model/PowerSample.swift    PowerSample / AppUsage / PowerBand，残差与覆盖率唯一定义
  PowerSampler.swift         2s 节拍 + 历史环形缓冲 + Capabilities 能力探测结果
  Probe/                     SMC / BatteryTelemetry / PowerResolver /
                             EnergyProbe / ProcessResolver / PortProbe
  Store/                     SQLiteStore / Downsampler / HistoryTiers / AppUsageAggregator
Sources/PowerFlow/           菜单栏 App
  App/                       main（AppKit 启动）/ AppController / RenderMode
  UI/                        PanelView / FlowDiagram / TrendChart / TrendWindow / Theme
Sources/PowerFlowProbe/      终端诊断入口（--dump / --battery / --energy / --rounds）
Tests/PowerFlowCoreTests/    17 个测试
```

与最初设想的差异：把采样层拆成 `PowerFlowCore` 独立 target，是为了让 CLI 与 App 共用同一份读取逻辑 ——
调试时能确保"命令行看到的数字"和"UI 上显示的数字"来自同一条代码路径。

---

## 7. 准确性验证方案

不能只靠"看起来对"。三条对照：

1. **总量**：与 `sudo powermetrics --samplers cpu_power -n1 -i500` 的 CPU+GPU 功率对比，容差 ±10%
2. **单 App**：打开活动监视器能耗页，与同一 App 的能耗影响排序对比，Top 5 顺序应一致
3. **预算闭合**：连续 5 分钟静置 + 连续 5 分钟跑编译，两次的归因覆盖率都应落在 60–85%，且残差波动 < 2W

---

## 8. 已知局限（会写进 README，不藏）

- `rusage` 能量是 SoC 侧记账，不含屏幕与无线，所以残差是**必然存在**的，不是 bug
- 背光 `PDBR` 只是背光，不是整块面板耗电
- USB-C 口位映射（D1–D4 → 物理口）未在所有机型验证
- SMC 键在 Intel / 不同 Apple Silicon 代际上有差异，需能力探测
- 插电瞬间适配器协商阶段，`SystemPowerIn` 可能跳变，UI 需 2~3 个采样点平滑后再显示

---

## 9. 明确不做（v1 范围外）

- 充电上限 / 暂停充电 / SMC 写入 → 不碰，那需要 root helper，风险与收益不成比例
- 自动杀进程 → 只展示，不代用户决策
- 告警推送 / 快捷指令 / 计划任务
- 网络同步、账号、遥测

---

## 10. 已拍板的四个点

| 问题 | 结论 | 落地位置 |
| --- | --- | --- |
| 定位 | **趋势优先**，排行只作辅助 | 点开面板是流向图 + 「趋势」入口；趋势窗口是主战场 |
| 插电口径 | 主数字 = **系统负载**，充电功率作副标 | `PanelContent.headline` 左侧 `pSystem`，右侧 `chargePower` |
| 残差 | **画出来**（灰色堆叠带 + 覆盖率） | `PowerBand.residual`、`FlowDiagram` 的「未归因」分支 |
| 命名 | **PowerFlow** | 全项目 |

---

## 11. 实施进度

1. ✅ 骨架 + 采样层，命令行打印数字，与 `pmset` / 活动监视器对齐
2. ✅ 菜单栏 + popover + 流向图（流带按瓦数比例）
3. ✅ rusage v6 归因 + 进程按最外层 `.app` 归并
4. ✅ 趋势窗口：堆叠面积 + 实测总量线 + 电池副图 + 排行
5. ✅ SQLite 分层存储 + 降采样（2s/10s/60s）
6. ✅ 17 个单元测试；总量用 `pmset` 剩余时间反向校验

尚未做：鼠标悬停十字线读数、插拔电事件竖线标注、点击排行高亮曲线、告警。

---

## 12. 实测踩到的坑（回归时别踩第二遍）

1. **SMC 载荷是小端**。按大端读 `B0AV` 会得到 37V 这种荒谬电池电压。
2. **`KeyData` 必须 80 字节**。Swift 不给结构体末尾补填充，`KeyInfo` 里要显式加 3 字节 padding，
   否则只有 76 字节，后续字段全部错位。
3. **`ri_user_time` 是 mach tick（24MHz），不是纳秒**。必须过一遍 `mach_timebase_info`，
   否则 CPU 时间低估约 8 倍。
4. **`PowerTelemetryData` 是缓存值**。8 核拉满时 `SystemLoad` 从 45W 涨到 53W，它一个数字都不变；
   `PSTR` 与 `B0AV × B0AC` 是实时的。所以 **SMC 优先、遥测兜底**，反过来就废了。
5. **`BatteryPower` / `SystemLoad` 的符号会在不同读数间翻转**，只取绝对值，方向由充放电状态决定。
6. **`B0AV` 单位是毫伏**（约 12000），电压×电流要 `/1_000_000` 才是瓦特。
7. **充电功率要做预算收敛**：SMC 的电压×电流比实际入电高约 10%，
   用 `min(pack, input − system)` 约束，保证流向图自洽（实测插电态闭合误差 0.00W）。
8. **进程归并要取最外层 `.app`**（`range(of: ".app/")` 不带 `.backwards`），
   否则 Chrome Helper 会把同一个浏览器切成一堆条目。
9. **面板高度不能用未布局的 `sizeThatFits`**。先给定宽度跑 `layoutSubtreeIfNeeded`，
   再读 `fittingSize`，否则少算几十点，底部 App 行和「趋势」入口会被裁掉。
10. **测量用的 600pt 临时 frame 必须还原**。否则 SwiftUI 把内容在过高的视图里居中，
    弹层按 contentSize 裁剪时顶部状态行被切掉。
11. **菜单栏坐满时，状态项会被系统塞到时钟底下**（窗口 origin 落到 0 或负值），
    并且把「隐藏」写进本应用偏好（`NSStatusItem VisibleCC …`），之后不会自动恢复。
    重启 ControlCenter、换 activation policy、重建状态项都无效；只能自检位置后在启动时打开主窗口兜底。
12. **趋势窗口要设 `.moveToActiveSpace`**，否则从终端 / 登录项后台拉起时，窗口会开在别的 Space，用户看不到。
