# Yunqi Audio 全量开发 TODO（面向最终形态，Apple Silicon 优先）

这是一份“最终完美形态”的音频开发待办清单（不是 MVP）。

原则：
- **预览=导出同一真相**：`TimelineEvaluator -> AudioGraph`，实时与离线共用同一图语义。
- **Real‑Time Safe**：音频回调线程禁锁/禁分配/禁 IO/禁日志。
- **Apple Silicon 优先**：向量化（Accelerate/vDSP）、统一内存、后台任务系统、GPU 可视化。
- **可长期演进**：每一步都要为后续升级预留接口与数据模型，不靠“临时 if”。

> 相关文档：
> - `docs/audio-roadmap.md`：方向与架构
> - `docs/architecture.md`：整体分层

---

## 0. 先决条件（必须先做对，否则后面都会返工）

- [ ] 明确全局音频规范：内部 PCM 格式（建议 float32）、引擎 sampleRate（建议固定 48k）、声道布局（mono/stereo/5.1/7.1.4 预留）
- [ ] 明确时间基准：fps ↔ sampleTime 的换算策略、rounding 规则、边界条件（loop、trim、speed）
- [ ] 设定质量档位：`realtime` / `high`（与视频一致），并定义每档允许的算法/开销
- [ ] 设定实时线程规则与审计：约束列表 + lint/测试手段（避免误用锁、分配）
- [ ] 定义 AudioGraph 版本号与序列化：用于缓存 key、诊断 dump、未来迁移

---

## 1. 数据模型与命令系统（EditorCore）

### 1.1 Clip/Track 音频属性（面向最终形态一次到位）
- [x] Clip 音频基础属性：gain、mute、solo（如果 clip 级别需要）、pan/balance、通道映射（L/R/mono）（阶段性已落地：clip mute/solo 数据模型 + 命令 + evaluator 语义）
- [x] Fade：入/出淡入淡出（形状：线性/等功率等，Phase 1：数据模型 + 命令 + evaluator 语义节点，DSP 后续落地）
- [ ] Automation：
  - [ ] 音量曲线（关键帧：time,value；插值类型；曲线张力/平滑）
  - [ ] Pan 曲线
  - [ ] 效果参数曲线（为 EQ/Dynamics 预留）
- [ ] Role / Subrole / Lane 标注：对话/音乐/效果（对标 FCP），并为 stem 导出预留
- [ ] Track/Bus：轨道输出目标（main / submix bus / role bus），为 sends/returns 预留

### 1.2 Undo/Redo 覆盖（必须 100%）
- [ ] 每个音频编辑动作都有 Command（一次操作一次撤销）
- [ ] 命令可序列化（可选，用于诊断与宏/脚本化）

- [x] 已支持：设置/清除 Clip 音频 loop（Undo/Redo）：`ProjectEditor.setClipAudioLoopRangeSeconds`（`Sources/EditorCore/EditorCore.swift`）+ 单测 `Tests/EditorCoreTests/EditorCoreTests.swift`
- [x] 已支持：Slip（仅修改 `sourceInSeconds`，不动 timeline/duration，Undo/Redo）：`ProjectEditor.slipClip`（`Sources/EditorCore/EditorCore.swift`）+ 单测 `Tests/EditorCoreTests/EditorCoreTests.swift`
- [x] 已支持：Clip 音频参数编辑（Undo/Redo）：`ProjectEditor.setClipGain` / `setClipPan` / `setClipAudioTimeStretchMode` / `setClipAudioReversePlaybackMode`（`Sources/EditorCore/EditorCore.swift`）+ 单测 `Tests/EditorCoreTests/EditorCoreTests.swift`
- [x] 已支持：Clip 音频 mute/solo（Undo/Redo）：`ProjectEditor.setClipAudioMuted` / `setClipAudioSolo`（`Sources/EditorCore/EditorCore.swift`）+ 单测 `Tests/EditorCoreTests/EditorCoreTests.swift`
- [x] 已支持：Track 音频参数编辑（Undo/Redo）：`ProjectEditor.setTrackVolume` / `setTrackPan`（`Sources/EditorCore/EditorCore.swift`）+ 单测 `Tests/EditorCoreTests/EditorCoreTests.swift`
- [x] 已支持：Clip Fade In/Out（Undo/Redo）：`ProjectEditor.setClipFadeIn` / `setClipFadeOut`（`Sources/EditorCore/EditorCore.swift`）+ 单测 `Tests/EditorCoreTests/EditorCoreTests.swift`

---

## 2. TimelineEvaluator 输出 AudioGraph（EditorEngine）

### 2.1 AudioGraph 定义（与 RenderGraph 对称）
- [ ] 定义 `AudioGraph`：节点、边、输出端口（Main、Submix、Stems）
- [ ] 定义节点类型（至少）：Source、TimeMap、Gain、Pan、Fade、Bus、MeterTap、AnalyzerTap
- [ ] 定义参数快照：按时间点可查询（用于实时与离线一致性）
  - [x] Phase 1：`TimelineEvaluator.evaluateAudioGraph` 已支持对 clip `volumeAutomation` / `panAutomation` 做时间点求值（线性/hold），并落到 `.gain/.pan` 节点常量值（逐采样 automation 后续由 renderer 接管）。
  - [x] Phase 1：显式参数快照结构（`AudioGraph.parameterSnapshot`）已落地，可直接查询每个参与混音的 clip 的 effective gain/pan/mute 等（用于诊断与 golden tests）。

### 2.2 图编译（Graph Compile）
- [ ] 编译为可执行计划：拓扑排序、常量折叠、节点合并（例如连续 gain 合并）
- [ ] 资源绑定：为每个 Source 绑定 decode/cache 句柄
- [ ] 缓存 key：图结构 hash + 参数版本

### 2.3 时间映射（Time Map）
- [x] Phase 1：纯类型/纯函数时间映射骨架（含 speed/reverse/loop + trim/slip 语义入口，不接入播放路径）：`Sources/EditorEngine/AudioTimeMap.swift` + 单测 `Tests/EditorEngineTests/EditorEngineTests.swift`
- [x] Trim/Slip/Loop 映射到 sample 精度（图语义层已表达）：`Sources/EditorEngine/TimelineEvaluator.swift`（产出 sample 级 `timeMap`）+ `Sources/EditorEngine/AudioGraph.swift`（TimeMap 节点携带 `AudioTimeMap`）+ 单测 `Tests/EditorEngineTests/EditorEngineTests.swift`
- [x] Speed（匀速）映射：
  - [x] 先定义策略（保持音高 vs 随速度变）并做接口（已落地：`AudioTimeStretchMode` + `AudioNodeSpec.timeMap(mode:map:)`）
  - [x] 为后续变速曲线/高质量 time‑stretch 预留扩展点（通过 `AudioTimeMap`/`AudioTimeStretchMode` 扩展即可，不改图语义）

---

## 3. 解码与媒体 IO（MediaIO / DecodePipeline）

### 3.1 统一解码接口
- [x] `AudioDecodeSource` 抽象：从音频文件或视频容器提取音轨（已落地：`Sources/MediaIO/AVFoundationAudioDecodeSource.swift`）
- [ ] 支持常见格式：AAC/MP3/WAV/AIFF/ALAC（按系统能力）
- [ ] 元数据解析：sampleRate、channelCount、duration、loudness（可后置）

### 3.2 实时友好的缓存与预取
- [ ] 分段 PCM cache（ring / chunk）
- [ ] Seek 预取：playhead 前后窗口（按速率动态调整）
- [x] 多分辨率波形缓存：峰值/均方根，mip 级别
- [x] 缓存持久化：`Storage` 下按 key 存储，可失效/可重建（已落地：`AudioPCMCache` + `WaveformCache.invalidate`，并通过 `assetFingerprint` 避免素材变更误复用）

### 3.3 代理音频（可选但建议）
- [ ] 背景生成代理（例如 48k float32、或轻量压缩 PCM）
- [ ] 代理切换策略：播放优先代理，暂停/导出用原始（可配置）

---

## 4. 音频渲染执行器（Realtime / Offline）

### 4.1 RealtimeRenderer（Core Audio 输出）
- [ ] 设备选择、采样率协商、buffer size 管理
- [ ] RT-safe buffer pool（固定容量、无锁或 lock-free）
- [ ] 音画同步：与视频 playhead 共用主时钟策略（或明确谁是 master）
- [ ] 播放控制：play/pause/stop/loop/scrub
- [ ] J/K/L 策略：
  - [ ] 正放变速：音频是否变速/变调策略
  - [ ] 倒放：先定义“是否静音/粗糙反向”策略，架构上允许未来升级

### 4.2 OfflineRenderer（导出/预渲染）
- [ ] 离线渲染接口：给定时间范围、输出 sampleRate/声道布局
- [ ] 多线程策略：并行于轨道/块（block）维度（确保确定性）
- [ ] 高质量算法入口：离线专用 time-stretch、线性相位 EQ 等（后续实现）

### 4.3 混音核心（DSP）
- [ ] 多轨叠加：vDSP 向量化 mix、增益、pan
- [ ] 去爆音：淡入淡出边界 click/pop 处理、交叉淡化（crossfade）
- [ ] 采样率转换（SRC）：输入与引擎 sampleRate 不一致时的高质量重采样（实时/离线两档）

---

## 5. 效果系统（Effects / Plugin）

### 5.1 内置效果（先内建，接口可扩展）
- [ ] EQ：参数化 EQ（至少 3~8 段），支持 automation
- [ ] Dynamics：compressor / limiter / expander / gate（master/track/clip 级别）
- [ ] Reverb / Delay（send/return）：先做基础算法与路由
- [ ] Noise gate / De-esser（可后置）

### 5.2 插件体系（为超越预留）
- [ ] 抽象 `AudioEffectNode` 生命周期：prepare/reset/process
- [ ] 参数系统：
  - [ ] 参数元数据（范围/单位/默认值）
  - [ ] 参数自动化映射
- [ ] 可选：AU（Audio Units）桥接容器（不必立刻做，但要避免未来架构冲突）

---

## 6. 混音路由（Buses / Roles / Stems）

- [ ] Track buses：每轨输出到某个 bus
- [ ] Role buses：按对话/音乐/效果聚合（对标 FCP Roles）
- [ ] Sends/Returns：可配置 send 量，支持 automation
- [ ] Master chain：最终 limiter、dither（如输出到 16-bit PCM）
- [ ] Stem 导出：按 Role 或按 Bus 输出多文件/多轨道

---

## 7. 计量与分析（Meters / Analysis）

### 7.1 Meters（实时）
- [ ] 峰值/True Peak（可后置）
- [ ] RMS
- [ ] LUFS（Integrated/Short-term/Momentary）
- [ ] Bus/Track/Clip 多级 meter tap

### 7.2 Analysis（后台）
- [ ] 波形分析（峰值 mip）
- [ ] 频谱（FFT）缓存
- [ ] 相位/相关度
- [ ] 分析任务系统：可取消、可恢复、可重算

---

## 8. UI/UX（时间线音频专业体验）

> UI 不是本 TODO 的主战场，但为了“最终完美”，需要早期把数据流与性能预算考虑进去。

- [ ] 波形显示：
  - [ ] 多分辨率波形，滚动/缩放按需加载
  - [ ] GPU 渲染波形（Metal），避免 CPU 画线
- [ ] 音量曲线编辑：关键帧创建/移动/框选/吸附
- [ ] 淡入淡出手柄：直观编辑与自动对齐
- [ ] Track Header：mute/solo/volume/pan/role
- [ ] Meters 面板：master/track meters
- [ ] Audio Inspector：选中 clip/track 显示所有参数与 automation
- [ ] Roles 管理 UI：角色分组、颜色（如将来设计系统允许）

---

## 9. 导出与交付（Delivery）

- [ ] 导出音频与视频的统一渲染：
  - [ ] 复用 AudioGraph + OfflineRenderer
  - [ ] 音画对齐与 drift 控制
- [ ] 输出格式：
  - [ ] AAC（容器 mp4/mov）
  - [ ] WAV/AIFF（PCM）
  - [ ] 多声道输出（5.1/7.1.4 预留）
- [ ] Loudness 目标：对标广播/流媒体规范（可配置）
- [ ] Stems 导出：多文件打包与命名规则

---

## 10. 性能、可观测性与稳定性（Apple Silicon 取胜点）

- [ ] Instruments 观测点：解码、缓存命中、混音、效果、IO 分段 `os_signpost`
- [ ] 实时健康指标：xruns、callback 时长分布、CPU 占用、功耗（可选）
- [ ] 调试开关：dump AudioGraph、dump 某段 PCM、dump meter 时序
- [ ] 资源回收：缓存上限、LRU、后台清理
- [ ] 多项目/多窗口：音频引擎实例管理（避免设备被重复占用）

---

## 11. 测试策略（必须覆盖“专业正确性”）

- [ ] 单元测试：
  - [ ] gain/pan/fade 的数值正确性
  - [ ] automation 插值正确性
  - [ ] time map（trim/loop/speed）边界正确性
- [ ] Golden tests：给定工程 + 时间范围，输出 PCM hash/统计量（RMS/peak/LUFS）
- [ ] 性能测试：多轨压力、长素材、频繁 seek
- [ ] 回归测试：全屏/变速/loop/scrub 下无爆音、无 drift

---

## 12. 推荐实施顺序（不等于 MVP，而是“底座优先、功能按层叠加”）

1) 规范与模型（第 0~2 节）
2) 解码与缓存（第 3 节）
3) RealtimeRenderer + 混音核心（第 4 节）
4) UI 波形/automation（第 8 节中与引擎强绑定的部分）
5) OfflineRenderer + 导出（第 4/9 节）
6) 效果系统与路由（第 5/6 节）
7) 分析与专业交付（第 7/9 节深水区）

---

## 13. 已拍板的 5 个关键决策（写死为“长期正确”，避免推倒重来）

> 这些决策从“专业 NLE + 深度 FCP 用户”的角度拍板：优先保证一致性、可复现、可扩展，并最大化 Apple Silicon 的吞吐与低延迟优势。

### 13.1 引擎内部 sampleRate：固定 48k（素材/设备通过 SRC 对齐）

- 结论：引擎内部统一 `48_000 Hz` + `float32` PCM；输入素材与输出设备可以是 44.1k/48k/96k，但进入引擎与离开引擎都通过 SRC。
- 影响点（必须落实到代码/缓存设计）：
  - `AudioGraph` 运行时基：以 48k sampleTime 为主，timeline time 只做上层语义。
  - 缓存 key 必须包含：源采样率/声道布局/目标 48k/算法版本号（避免升级后错用缓存）。
  - RealtimeRenderer：优先设备同 48k；若不同，设备侧做轻量 SRC。
  - OfflineRenderer：一律渲染到 48k，再按导出格式做最终封装/重采样（若需要）。

### 13.2 变速默认语义：保持音高（Keep Pitch），并允许 per‑clip 切换 Varispeed

- 结论：默认 **Keep Pitch**；每个 clip 必须有明确策略位：`keepPitch` / `varispeed` / `muteAudio`（先把语义固化，算法后续可升级）。
- 影响点：
  - 数据模型（EditorCore）：clip 增加 `audioTimeStretchMode`（枚举），并可被 automation/导出读取。
  - AudioGraph：TimeMap/TimeStretch 节点必须能表达该模式；Realtime/Offline 仅替换“质量实现”，不改语义。
  - 质量档位：realtime 可先用低延迟实现；offline 走高质量算法。

### 13.3 倒放（J 负速率）音频：默认静音（realtime），可选粗糙/高质量倒放（离线优先）

- 结论：默认倒放静音；预留策略枚举：`mute` / `roughReverse` / `highQualityReverse`。
- 影响点：
  - 播放控制（EditorEngine）：当 rate < 0 时，AudioGraph 选择对应策略节点（先实现 mute）。
  - OfflineRenderer：未来可实现 highQualityReverse（如需要“可交付的倒放音频”）。
  - UI/偏好：后续可加开关，但底层语义必须先存在。

### 13.4 插件策略：先内置效果为主；预留 AU 容器接口，不承诺早期 AU 兼容

- 结论：优先把内置 EQ/Dynamics/Reverb/Delay 做到专业可用；插件体系以 `AudioEffectNode` + 参数系统为核心；AU 只做“架构预留”。
- 影响点：
  - 参数系统必须一开始就支持：范围/单位/默认值/曲线自动化映射/序列化（用于工程文件与缓存 key）。
  - 节点生命周期必须 RT-safe：prepare/reset/process，且 process 不得分配/加锁。
  - 未来 AU：以“容器节点”接入（隔离线程/状态/格式协商复杂度），不污染内核。

### 13.5 Roles/Bus：模型与 AudioGraph 现在就预留；UI 与交付分阶段开放

- 结论：Roles（dialogue/music/effects）与 bus routing 作为“工程骨架”立刻进入模型与 AudioGraph；对外 UI 与 stems/loudness 等交付能力可后置。
- 影响点：
  - EditorCore：clip/track 增加 role/subrole、output bus、send 参数等字段（即使 UI 暂不暴露）。
  - AudioGraph：必须支持 main bus + role bus 的路由表达，并为 stems 输出端口预留。
  - 导出（Delivery）：stems 导出只是一种“输出选择”，不应重写渲染逻辑。

---

## 14. 接口落地清单（代码骨架：把“决策”变成可演进的类型边界）

这一节的目标不是实现功能，而是把未来一定会需要的“边界与接口”一次定好：
- 后续迭代只在这些边界内增加实现/优化，不靠推倒重来。
- 所有接口要支持：realtime/high 两档质量、可序列化参数、可缓存 key、可测试（deterministic）。

### 14.1 EditorCore（数据模型：工程文件的长期稳定面）

- [x] `AudioTimeStretchMode`（枚举）：`keepPitch` / `varispeed` / `muteAudio`（已落地：`Sources/EditorCore/EditorCore.swift`）
- [x] `AudioReversePlaybackMode`（枚举）：`mute` / `roughReverse` / `highQualityReverse`（已落地：`Sources/EditorCore/EditorCore.swift`）
- [x] `AudioRole` / `AudioSubrole`：对标 FCP Roles（已落地：`Sources/EditorCore/EditorCore.swift`）
- [x] `AudioAutomationCurve<T>`：关键帧曲线 + `version`（已落地：`Sources/EditorCore/EditorCore.swift`）
- [x] Clip 音频字段（阶段性落地）：gain/pan、automation（volume/pan）、timeStretchMode/reversePlaybackMode、role/subrole、outputBusId（已落地：`Sources/EditorCore/EditorCore.swift`）
  - [ ] fadeIn/fadeOut（含曲线形状）
  - [ ] send 参数（为 sends/returns 预留）
- [x] Track/Bus 字段（阶段性落地）：mute/solo/volume/pan、role/subrole、outputBusId（已落地：`Sources/EditorCore/EditorCore.swift`）
  - [ ] send/return 定义

### 14.2 EditorEngine（评估与调度：单一真相的生成者）

- [x] `AudioGraph`（纯数据结构，可哈希/可序列化）（已落地：`Sources/EditorEngine/AudioGraph.swift`）
  - [x] `nodes: [AudioNodeID: AudioNodeSpec]`
  - [x] `edges: [AudioEdge]`
  - [x] `outputs: AudioGraphOutputs`（当前：main 预留；submix/stems 后续补）
  - [x] `version`
- [x] `AudioNodeSpec`（枚举，可序列化）（已落地：`Sources/EditorEngine/AudioGraph.swift`）
  - [x] `source(clipId, assetId, format)`（Phase 1：format 为可选 hint）
  - [x] `timeMap(mode, speed, reverseMode)`（Phase 1：trim/loop 后续补）
  - [x] `gain(value)` / `pan(value)`（Phase 1：automation 后续接入）
  - [x] `bus(id, role)`（Phase 1：sends 后续补）
  - [x] `meterTap` / `analyzerTap`（占位）
- [x] `AudioGraphCompiler`：`compile(graph, quality) -> AudioRenderPlan`（已落地：`Sources/EditorEngine/AudioGraph.swift`）
  - [x] 负责：拓扑排序（确定性）、常量折叠/节点合并（Phase 1：连续 gain 合并）、资源绑定（可选 binder）、plan hash（stableHash64）
- [x] `AudioClock`（48k 秒↔sampleTime 换算 + rounding 规则）（已落地：`Sources/EditorEngine/AudioClock.swift`）
  - [x] `MediaClock`（Phase 1：hostTime(ns) ↔ sampleTime 确定性换算 + loop 边界）—— `Sources/EditorEngine/MediaClock.swift`
- [x] `PlaybackSyncPolicy`（占位枚举）（已落地：`Sources/EditorEngine/AudioClock.swift`）

### 14.3 MediaIO（解码与格式：把“文件”变成可用 PCM）

- [x] `AudioSourceFormat`（Phase 1：sampleRate + channelCount；channelLayout 后续补）（已落地：`Sources/AudioEngine/AudioEngine.swift`）
- [x] `AudioDecodeSource`（协议壳，占位）（已落地：`Sources/MediaIO/AudioDecode.swift`）
  - [x] `readPCM(startFrame: Int64, frameCount: Int) -> AudioPCMBlock`
  - [x] `preferredChunkFrames` / `durationFrames`
- [x] `AudioResampler`（协议壳，占位）（已落地：`Sources/MediaIO/AudioDecode.swift`）
  - [x] `process(input, fromRate, toRate, quality) -> output`
  - [x] realtime/high 两档实现（`Sources/MediaIO/LinearAudioResampler.swift`）

### 14.4 RenderEngine 或新 AudioEngine 模块（执行器：Realtime/Offline 共用核心）

> 音频执行器建议独立成模块（例如 `AudioEngine`），保持与视频 `RenderEngine` 对称；但也可以先放在 `RenderEngine` 下，后续再拆。

- [ ] `AudioBuffer` / `AudioBufferPool`
  - [x] 固定容量 buffer + pool 接口与默认实现（Phase 1：非 RT-safe，内部仍有锁；borrow/recycle 不再额外堆分配；并提供预分配不增长的 pool 变体；已落地：`Sources/AudioEngine/AudioEngine.swift`）
  - [x] RT-safe 获取与归还（无锁/无分配/无 IO；预分配 + 原子 freelist；耗尽返回 empty buffer；已落地：`Sources/AudioEngine/AudioEngine.swift`（`RealtimeAudioBufferPool`））
- [x] `AudioPCMBlock`：多声道 float32 interleaved（Phase 1 写死为 interleaved）（已落地：`Sources/AudioEngine/AudioEngine.swift`）
- [x] `AudioRenderQuality`：`realtime` / `high`（已落地：`Sources/AudioEngine/AudioEngine.swift`）
- [x] `AudioRenderPlan`（Phase 1：纯数据 plan + ordered nodes + stableHash64）（已落地：`Sources/EditorEngine/AudioGraph.swift`）
- [x] `AudioNodeRuntime`（协议壳，占位）（已落地：`Sources/AudioEngine/AudioRuntime.swift`）
  - [x] `prepare(format, maxFrames)`
  - [x] `reset()`
  - [x] `process(context, frameCount, pool) -> AudioBufferLease`
- [x] `RealtimeAudioRenderer`（协议壳，占位）（已落地：`Sources/AudioEngine/AudioRuntime.swift`）
  - [x] `setLoop(range)`（sampleTime range；默认 no-op）
- [x] `OfflineAudioRenderer`（协议壳，占位）（已落地：`Sources/AudioEngine/AudioRuntime.swift`）

### 14.5 Storage（缓存：波形/分析/代理/渲染）

- [x] `AudioCacheKey`（Phase 1：assetId + clipId + planStableHash64 + algorithmVersion + format）（已落地：`Sources/Storage/AudioCache.swift`）
  - [x] assetFingerprint（后续补：用于路径/内容变更失效）
  - [ ] 参数版本（后续补：区分 automation/效果参数变更）
- [x] `WaveformCache`：多分辨率 mip（peak/RMS），按缩放级别读取
- [x] `WaveformCache`：基础实现（Phase 1：peak/RMS 生成 + 持久化 + 按需 resample）—— `Sources/Storage/WaveformCache.swift`
- [ ] `AnalysisCache`：FFT/相位/相关度等后台产物
- [ ] `ProxyAudioCache`：代理音频文件与元数据

### 14.6 观测与测试（必须为专业可交付保驾护航）
- [x] xrun/underflow 计数（Phase 1：buffer pool underflow + snapshot；已落地：`Sources/AudioEngine/AudioEngine.swift`）
- [x] callback 耗时分布（Phase 1：桶统计 + 收集器接口；当前 lock-based，非 RT-safe）—— `Sources/AudioEngine/AudioEngine.swift`（`AudioCallbackTimingSnapshot` / `AudioCallbackTimingCollector`）
- [x] cache hit/miss（Phase 1：计数 + 按 cacheKind 分桶 + 收集器接口；当前 lock-based，非 RT-safe）—— `Sources/AudioEngine/AudioEngine.swift`（`AudioCacheMetricsSnapshot` / `AudioCacheMetricsCollector` / `AudioCacheKind`）
- [x] `AudioGraphDump`：稳定序列化输出（用于复现与问题定位；节点/边按 ID 排序，JSON sortedKeys；包含 `parameterSnapshot`）—— `Sources/EditorEngine/AudioGraphDump.swift`
- [x] Golden tests 输入/输出规范（Phase 1：PCM 统计 peak/RMS + 稳定 hash64 + 可序列化 snapshot；LUFS 等后续补）—— `Sources/AudioEngine/AudioGolden.swift`
  - [x] Golden case 描述与稳定 key/文件名（Phase 1：稳定 key 只由输入决定；无 IO）—— `Sources/EditorEngine/GoldenAudioCase.swift`
  - [x] Golden runner 入口（Phase 1：case -> OfflineAudioRenderer -> snapshot；仍不实现真正 renderer）—— `Sources/EditorEngine/GoldenAudioRunner.swift`
  - [x] Golden snapshot 文件落盘与对比（Phase 1：JSON IO + `YUNQI_UPDATE_GOLDENS=1` 更新）—— `Sources/EditorEngine/GoldenAudioStore.swift` / `Tests/EditorEngineTests/Goldens/`
