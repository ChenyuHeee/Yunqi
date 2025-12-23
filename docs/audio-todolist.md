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
- [ ] Clip 音频基础属性：gain、mute、solo（如果 clip 级别需要）、pan/balance、通道映射（L/R/mono）
- [ ] Fade：入/出淡入淡出（形状：线性/等功率等，先定义枚举并可扩展）
- [ ] Automation：
  - [ ] 音量曲线（关键帧：time,value；插值类型；曲线张力/平滑）
  - [ ] Pan 曲线
  - [ ] 效果参数曲线（为 EQ/Dynamics 预留）
- [ ] Role / Subrole / Lane 标注：对话/音乐/效果（对标 FCP），并为 stem 导出预留
- [ ] Track/Bus：轨道输出目标（main / submix bus / role bus），为 sends/returns 预留

### 1.2 Undo/Redo 覆盖（必须 100%）
- [ ] 每个音频编辑动作都有 Command（一次操作一次撤销）
- [ ] 命令可序列化（可选，用于诊断与宏/脚本化）

---

## 2. TimelineEvaluator 输出 AudioGraph（EditorEngine）

### 2.1 AudioGraph 定义（与 RenderGraph 对称）
- [ ] 定义 `AudioGraph`：节点、边、输出端口（Main、Submix、Stems）
- [ ] 定义节点类型（至少）：Source、TimeMap、Gain、Pan、Fade、Bus、MeterTap、AnalyzerTap
- [ ] 定义参数快照：按时间点可查询（用于实时与离线一致性）

### 2.2 图编译（Graph Compile）
- [ ] 编译为可执行计划：拓扑排序、常量折叠、节点合并（例如连续 gain 合并）
- [ ] 资源绑定：为每个 Source 绑定 decode/cache 句柄
- [ ] 缓存 key：图结构 hash + 参数版本

### 2.3 时间映射（Time Map）
- [ ] Trim/Slip/Loop 映射到 sample 精度
- [ ] Speed（匀速）映射：
  - [ ] 先定义策略（保持音高 vs 随速度变）并做接口
  - [ ] 为后续变速曲线/高质量 time‑stretch 预留扩展点

---

## 3. 解码与媒体 IO（MediaIO / DecodePipeline）

### 3.1 统一解码接口
- [ ] `AudioDecodeSource` 抽象：从音频文件或视频容器提取音轨
- [ ] 支持常见格式：AAC/MP3/WAV/AIFF/ALAC（按系统能力）
- [ ] 元数据解析：sampleRate、channelCount、duration、loudness（可后置）

### 3.2 实时友好的缓存与预取
- [ ] 分段 PCM cache（ring / chunk）
- [ ] Seek 预取：playhead 前后窗口（按速率动态调整）
- [ ] 多分辨率波形缓存：峰值/均方根，mip 级别
- [ ] 缓存持久化：`Storage` 下按 key 存储，可失效/可重建

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

- [ ] `AudioTimeStretchMode`（枚举）：`keepPitch` / `varispeed` / `muteAudio`
- [ ] `AudioReversePlaybackMode`（枚举）：`mute` / `roughReverse` / `highQualityReverse`
- [ ] `AudioRole` / `AudioSubrole`：对标 FCP Roles（先定义基础三类 + 自定义扩展）
- [ ] `AudioAutomationCurve<T>`：关键帧曲线（time,value,interpolation），并具备序列化格式版本号
- [ ] Clip 音频字段：
  - [ ] gain（线性/分贝表现层可分离）、pan/balance、fadeIn/fadeOut（含曲线形状）
  - [ ] timeStretchMode（见上）、reversePlaybackMode（见上）
  - [ ] role/subrole、outputBusId、send 参数（为后续 sends/returns 预留）
- [ ] Track/Bus 字段：mute/solo/volume/pan、role bus 路由、send/return 定义

### 14.2 EditorEngine（评估与调度：单一真相的生成者）

- [ ] `AudioGraph`（纯数据结构，可哈希/可序列化）：
  - [ ] `nodes: [AudioNodeID: AudioNodeSpec]`
  - [ ] `edges: [AudioEdge]`
  - [ ] `outputs: AudioGraphOutputs`（main/submix/stems）
  - [ ] `version`（用于缓存与迁移）
- [ ] `AudioNodeSpec`（枚举/协议二选一，但必须可序列化）：
  - [ ] `source(clipId, assetId, channelLayout, sourceFormat)`
  - [ ] `timeMap(mode, speed, trim, loop, reverseMode)`
  - [ ] `gain(value/automation)` / `pan(value/automation)` / `fade(params)`
  - [ ] `bus(id, role, sends)`
  - [ ] `meterTap(kind)` / `analyzerTap(kind)`
- [ ] `AudioGraphCompiler`：`compile(graph, quality) -> AudioRenderPlan`
  - [ ] 负责：拓扑排序、常量折叠、节点合并、资源绑定、plan hash（用于缓存）
- [ ] `AudioClock` / `MediaClock`：
  - [ ] `timelineTimeSeconds` ↔ `sampleTime` ↔ `hostTime` 的统一换算（48k 内部时基）
  - [ ] loop 边界与 rounding 规则
- [ ] `PlaybackSyncPolicy`：定义音画同步策略（谁为 master、漂移修正策略）

### 14.3 MediaIO（解码与格式：把“文件”变成可用 PCM）

- [ ] `AudioSourceFormat`：sampleRate、channelCount、channelLayout、sampleType（float32）
- [ ] `AudioDecodeSource`：
  - [ ] `readPCM(startSample: Int64, frameCount: Int) -> AudioPCMBlock`
  - [ ] `preferredChunkSize` / `durationSamples`
- [ ] `AudioResampler`：
  - [ ] `process(input, fromRate, toRate, quality) -> output`
  - [ ] realtime/high 两档实现

### 14.4 RenderEngine 或新 AudioEngine 模块（执行器：Realtime/Offline 共用核心）

> 音频执行器建议独立成模块（例如 `AudioEngine`），保持与视频 `RenderEngine` 对称；但也可以先放在 `RenderEngine` 下，后续再拆。

- [ ] `AudioBuffer` / `AudioBufferPool`：固定容量、RT-safe 获取与归还
- [ ] `AudioPCMBlock`：多声道 float32 planar/interleaved（选一种并写死）
- [ ] `AudioRenderQuality`：`realtime` / `high`
- [ ] `AudioRenderPlan`：编译后的可执行计划（节点实例 + 调度信息）
- [ ] `AudioNodeRuntime`：
  - [ ] `prepare(format, maxFrames)`
  - [ ] `reset()`
  - [ ] `process(context, frameCount) -> AudioPCMBlock`（必须 RT-safe）
- [ ] `RealtimeAudioRenderer`：
  - [ ] `start()/stop()/setRate()/seek()/setLoop(range)`
  - [ ] 渲染回调里只消费 `AudioRenderPlan` 与缓存数据
- [ ] `OfflineAudioRenderer`：
  - [ ] `render(range, format) -> AudioPCMStream`（支持 stems 输出）

### 14.5 Storage（缓存：波形/分析/代理/渲染）

- [ ] `AudioCacheKey`：
  - [ ] assetFingerprint + clipId + 参数版本 + AudioGraph/Plan hash + 算法版本 + 输出格式
- [ ] `WaveformCache`：多分辨率 mip（peak/RMS），按缩放级别读取
- [ ] `AnalysisCache`：FFT/相位/相关度等后台产物
- [ ] `ProxyAudioCache`：代理音频文件与元数据

### 14.6 观测与测试（必须为专业可交付保驾护航）

- [ ] `AudioDiagnostics`：xrun 计数、callback 耗时分布、cache hit/miss
- [ ] `AudioGraphDump`：序列化输出（用于复现与问题定位）
- [ ] Golden tests 输入/输出规范：指定工程与时间范围，输出统计（RMS/peak/LUFS）与可比对的 hash
