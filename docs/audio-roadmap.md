# Yunqi 音频系统长期规划（Apple Silicon 优先，对标/超越 Final Cut Pro）

本文以“专业 NLE 音频子系统”的视角，规划 Yunqi 的音频能力、底层架构与迭代里程碑。

执行清单见：`docs/audio-todolist.md`。

核心目标：
- **预览=导出同一真相**：`TimelineEvaluator -> AudioGraph`（与 `RenderGraph` 同源），实时播放与离线导出共用同一套评估与渲染器。
- **Apple Silicon 优先**：低延迟、可扩展、能充分利用向量化（Accelerate/vDSP）、统一内存、实时线程能力；UI 可视化（波形/频谱）尽可能 GPU 化。
- **专业工作流对标 Final Cut Pro**：从“剪辑可用”到“混音可交付”，同时预留能超越的扩展点（例如更强的可视化、可重复的渲染、可编程的链路与更好的缓存系统）。

---

## 0. 不可妥协的工程约束（音频版）

1) **音画同步与确定性**
- 同一工程、同一时间点、同一参数：输出必须 deterministic（位级可不完全一致，但应在可接受误差内且可解释）。
- 时间基准统一：Engine 以时间线秒/帧为主语义，Audio 渲染以 sampleTime 为主，必须有稳定换算策略（fps 与 sampleRate 的桥接）。

2) **实时线程规则（Real‑Time Safe）**
- 音频渲染回调内：禁止分配内存、禁止锁、禁止文件 IO、禁止日志、禁止任何可能阻塞的操作。
- 一切重活（解码、缓存构建、分析）都在后台队列完成，实时线程只做“拷贝/混音/滤波”。

3) **预览与导出共用同一套 AudioGraph**
- 实时播放：允许降级（质量档位），但图结构与参数语义不变。
- 离线导出：质量优先，走同一 graph + 更高阶算法/更高精度/更高 oversampling。

4) **缓存可计算、可失效**
- 波形缓存、频谱缓存、代理音频、渲染缓存都由 key 驱动（assetFingerprint + 参数 + 版本号）。

---

## 1. 长期架构：AudioGraph + Renderer + Cache

### 1.1 AudioGraph（与 RenderGraph 对称）
建议把音频也抽象为“可评估的图”，由 `TimelineEvaluator` 在任意时间点输出：
- **图结构**：节点（Node）+ 连接（Edge）+ 输出（Main / Submix / Stems）
- **节点类型（长期）**：
  - Source：音频素材（含从视频中抽取音轨）
  - ClipTime：trim / slip / 速度映射（time map）
  - Gain：clip gain / track volume / automation
  - Pan / Balance：立体声/多声道声像
  - EQ：parametric EQ（后续可扩展到 match EQ）
  - Dynamics：compressor / limiter / expander / gate
  - Send/Return：混响/延迟等并行效果
  - Bus：submix bus（轨道组、角色、stem 输出）
  - MeterTap：峰值/RMS/响度（LUFS）采样点
  - AnalyzerTap：频谱/相位/相关度

**关键**：
- `AudioGraph` 的坐标系与 `RenderGraph` 相同（timeline time），但渲染时以 sample 为最小单位。

### 1.2 AudioRenderer（实时/离线两种执行器）
- **RealtimeRenderer**：Core Audio 输出，低延迟；支持播放/暂停/loop/scrub，sample‑accurate 对齐。
- **OfflineRenderer**：用于导出/预渲染/代理生成；可 multi‑pass，允许更高质量算法。

建议执行器共用：
- 同一套 graph 编译（graph compile）
- 同一套节点实现（node DSP），只是“运行约束与质量策略”不同。

### 1.3 解码与缓存层（AudioCache / DecodePipeline）
- **解码**：从音频文件或视频容器中抽取 PCM（优先 float32，内部统一）。
- **缓存**：
  - 波形（多分辨率 mip）：用于时间线缩放、快速绘制
  - 分段 PCM cache：用于 scrubbing / 快速 seek
  - 代理音频（可选）：对超大素材/多轨场景降低 CPU 压力

---

## 2. Apple Silicon 优先：性能与系统选型建议

### 2.1 音频渲染底座（Core Audio / AudioUnit）
目标是“专业 DAW/NLE 级”低延迟与稳定性：
- 输出：Core Audio HAL（或基于 `AUAudioUnit`/AudioUnit 的 render callback）
- 线程：使用 real‑time 优先级，避免与 UI 抢锁；必要时考虑 WorkGroup（仅在可控范围内）
- Buffer：统一 buffer pool（固定大小环形缓冲区），避免频繁分配

### 2.2 向量化与 DSP（Accelerate/vDSP）
Apple Silicon 的优势之一是向量化吞吐：
- 混音（N 路叠加）/增益/淡入淡出：用 vDSP 批处理
- EQ/滤波：优先 biquad（可用 vDSP biquad / 自实现向量化）
- 频谱/FFT：vDSP FFT + 预计算 window
- 波形抽样/峰值：vDSP max/abs

### 2.3 UI 可视化（波形/频谱）GPU 化
- 波形绘制：多分辨率波形数据 + Metal 绘制（减少 CPU 画线）
- 频谱/相位：分析在后台，显示层用 Metal（必要时做 downsample）

### 2.4 质量档位（realtime / high）
- realtime：
  - 限制并行效果与高成本算法（如高质量 time‑stretch、线性相位 EQ）
  - 降低 oversampling、减少 analyzer 频率
- high（暂停/逐帧/导出）：
  - 允许更高阶算法、更高精度与更密集分析

---

## 3. 对标 Final Cut Pro 的“音频语义清单”

### 3.1 基础剪辑（必须先对齐）
- Clip 音量（clip gain）+ 关键帧（automation）
- Track 音量/静音/solo
- 淡入淡出（clip 端点手柄）
- 音频波形（随缩放自适应，滚动按需加载）
- 角色/通道：至少区分“对话/音乐/效果”（后续扩展）

### 3.2 时间线语义（需要一次定对）
- 多轨叠加规则：同一轨内 clip 互斥/覆盖策略（现在已有 lane 思路，可扩展到 audio lane）
- 音画同步：
  - clip speed 变更对音频 time map 的影响
  - J/K/L（含倒放）对音频的策略（FCP 在倒放时音频通常处理不同；可先策略化）

### 3.3 混音与交付（专业级）
- 总线（Submix Buses）与发送（Sends）
- Master Limiter / Loudness 控制（LUFS/True Peak）
- Stems 导出（对话/音乐/效果分别导出）
- 媒体管理：把音频代理、渲染缓存纳入工程可恢复体系

---

## 4. “可超越 FCP”的长期方向（可选，但要预留接口）

> 这些不要求一开始就做，但架构上要避免卡死未来。

- 更强的可视化：实时频谱/相位/相关度、混音总线可视化
- 可编程/可复现的渲染：AudioGraph 可序列化（用于诊断与回放）
- 更强的分析与修复：降噪、去混响、响度自动对齐（可先做“接口与任务系统”，算法后置）
- 智能化工作流：自动分角色/自动压限目标、自动 ducking（基于 sidechain/标注）

---

## 5. 里程碑规划（建议顺序：先底座再花活）

### Milestone A1：音频基础闭环（MVP，但要“专业正确”）
验收标准：
- 支持音频 clip：导入、放到时间线、播放稳定
- clip gain / track volume / mute / solo
- 淡入淡出
- 音频波形（至少单分辨率）
- 导出：视频 + 音频（含音量/淡入淡出）一致

实现要点：
- `TimelineEvaluator -> AudioGraph` 初版
- RealtimeRenderer + OfflineRenderer 共用图
- 统一 PCM 格式（float32）与 buffer pool

### Milestone A2：自动化（Automation）与稳健混音
验收标准：
- 音量关键帧（曲线插值：线性/平滑）
- 基础 meter（peak/RMS）
- 多轨叠加性能可控（例如 8~16 路同时播放在 M 系列稳定）

### Milestone A3：基础效果（EQ / Dynamics）
验收标准：
- Parametric EQ（至少 3 段）
- Compressor / Limiter（Master 端）
- 效果参数可自动化

### Milestone A4：角色/总线/交付（接近专业交付）
验收标准：
- 角色（对话/音乐/效果）与 role-based submix
- Sends/Returns（混响/延迟）
- Loudness（LUFS）与 True Peak 控制
- Stems 导出

### Milestone A5：速度/变速与高质量算法
验收标准：
- 匀速变速（音高策略可选：保持音高/随速度变）
- 更高质量 time‑stretch（离线优先）

### Milestone A6：分析/修复/智能化（超越点）
- 降噪/去混响/自动 ducking 等：以“任务系统 + 插件接口”形式迭代

---

## 6. 测试与可观测性（音频必须重视）

### 6.1 单测/黄金测试
- AudioGraph 编译结果 deterministic（节点序列、参数快照）
- 关键场景：
  - clip gain + track volume + fade 的输出峰值/包络符合预期
  - loop 边界无爆音（click/pop）
  - 多轨叠加不丢样

### 6.2 性能指标（Apple Silicon 目标）
- 目标：realtime 播放下 audio callback 不 xruns
- 指标建议：
  - callback 预算：`bufferDuration * 0.5` 以内完成 DSP（留足余量）
  - 内存：缓存可控、可清理
  - 端到端延迟：可监测、可调（设备 buffer size）

### 6.3 诊断工具
- 可选 env 开关：dump 某段 PCM、导出某段 graph、记录 xruns
- `os_signpost` / Instruments：把解码、混音、效果、IO 分段标记

---

## 7. 与现有模块的对齐建议

- `EditorCore`：扩展 clip 的音频属性（gain、fade、pan、role、automation）
- `EditorEngine`：
  - `TimelineEvaluator` 输出 `AudioGraph`
  - 播放控制器负责“音画同步与调度策略”
- `RenderEngine`：保持对称（RenderGraph/AudioGraph）
- `MediaIO`（未来）：统一抽取音频与分析（duration/peak/metadata）
- `Storage`：波形缓存、代理音频、分析结果的持久化与失效

---

## 8. 最关键的“拍板点”（越早越省命）

1) 内部统一 PCM 格式：float32 + 统一 sampleRate（建议 engine 固定 48k，输入做重采样）
2) 变速策略：实时先做简单（可降级），离线再上高质量算法
3) 插件体系：是否要兼容系统 Audio Units（AUv3）？建议早期“内置效果优先”，但架构预留 AU 节点容器
4) 角色/总线：何时引入（建议 A4），但数据模型要提前预留字段
