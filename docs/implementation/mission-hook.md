# 任务采集器与 Hook：实现、部署和验证

版本：Hook 0.3.0，任务采集器 0.1.5。协议版本：1。1 Hz、事件预编码与对象属性合并发送保持不变；冻结快照续页有界推进，异常记录显式隔离。

设计依据：[架构](../architecture/mission-hook.md)、[协议](../protocol/mission-hook-v1.md)。C++ 主服务器及 TCP 接收已实现，详见 [服务器说明](server.md)；导播本地服务和网页正在实施。

发布形态为单文件：只部署生成的 `DcsEsportHook.lua` 到 `Scripts/Hooks`。任务采集器源码已嵌入该文件，仍由 Hook 注入任务环境运行。源码分模块只是开发组织方式，不是部署依赖。

## 1. 实现目录

| 路径 | 职责 |
| --- | --- |
| [src/shared/json.lua](../../src/shared/json.lua) | Lua 5.1 JSON 编解码、显式 null/数组、深拷贝；不执行输入数据 |
| [src/mission/collector.lua](../../src/mission/collector.lua) | 注入任务环境的采集器，依赖 DCS API，不依赖 io、socket 或 require |
| [src/hook/bridge.lua](../../src/hook/bridge.lua) | 跨环境适配、注入、拉取、确认入口、有限待确认队列 |
| [src/hook/recorder.lua](../../src/hook/recorder.lua) | JSON/JSONL 诊断输出；写文件成功不触发 ACK |
| [src/hook/DcsEsportHook.lua](../../src/hook/DcsEsportHook.lua) | 单文件 Hook 的引导模板及 DCS 回调保护；不要直接部署此源码模块 |
| [config/hook.example.lua](../../config/hook.example.lua) | 构建时内嵌到生成文件顶部的配置 |
| [tests](../../tests/suite.lua) | DCS API/定时器/事件/隔离环境模拟及行为测试 |
| [tools/package.py](../../tools/package.py) | 合并全部依赖，生成单文件 Hook 及 SHA-256 清单 |
| [tools/install.ps1](../../tools/install.ps1) | 仅安装生成的一个 Hook 文件 |
| [tools/smoke.py](../../tools/smoke.py) | 用真实 Hook 入口、模拟 DCS 和真实文件输出跑离线完整链路 |

## 2. 已实现行为

### 2.1 注入

生成文件顶部的配置表、JSON 编解码器、桥接及文件输出模块，以及任务采集器源码均已内嵌；运行时不读取外部 config.lua，不通过 loadfile/dofile/require 加载配套模块。内嵌的受控 Lua 模块通过 loadstring 在 Hook 环境创建，JSON 请求仍然按数据解析。

Hook 每个调度步骤只推进一个安装阶段：探测调用路线、检查实例、注入、初始化、正常拉取。探测按顺序尝试：

1. `net.dostring_in("mission", ...)` 内部调用 `a_do_script()`。
2. 直接在 `mission` 环境执行。
3. 直接在 `server` 环境执行。

仅当真正环境具备任务 API 且带标记的字符串正确往返时才使用该路线。可配置固定路线。嵌套调用会附加返回填充，并从返回位置中提取带固定前缀的业务字符串，兼容已知的返回错位形式；没有假设某个位置永远正确。

注入响应丢失后先探测已有实例，不无条件覆盖。正常拉取连续失败后重新探测。版本或来源不明确的已有实例保持原状，输出明确错误。

### 2.2 采集

- 飞机运动默认 1 Hz；明确输出三维速度和水平地速。
- 油量、弹药、玩家占用和生命值默认 1 Hz；相关事件标记待刷新。
- 燃油原始比例保留，不截断；绝对质量换算尚未启用，返回 null 和未验证标记。
- 当前武器按 API 条目输出类型、显示名、分类和计数；未知类型不与其他项合并。
- 已知 AI 的 isPlayer=false，不与 null 混淆。
- 导弹默认 1 Hz，逐发独立 ID；发射时即时读取并冻结发射平台及玩家快照。
- 发射者同时检查事件 initiator 与可用的 getLauncher；冲突保留两者并报告。
- 目标持续查询，保存首次观察、当前观察和历史最后目标；没有返回、失败和陈旧各自区分。
- 注册出生事件并周期校验飞机；对象消失后独立记录移除/跟踪结束，不推断命中。
- 对象和活跃导弹有内部硬上限，默认分别 8192 和 4096；触及上限明确报告覆盖不完整。当前无完整大规模压力验证。

### 2.3 缓存与确认

采集器保存最新状态和有界事件日志；Hook 维护单独的读取游标及确认游标。读取不删除日志，合法 ACK 才清理。事件条数/字节上限触发时返回可确认的缺失前缀。

Hook 默认最多暂存 2048 个日志项和约 8 MiB 编码数据；当前任务与保留的旧任务待确认队列共用这个上限。达到容量后停止继续拉新事件，继续读取状态及发送已经明确收到的当前源确认；不自动确认、不静默丢弃。本地诊断文件持续增长，不属于上述内存上限，需要在实机验证期间按任务归档。

快照分片全部收到后才替换 Hook 内的完整状态；后续页冻结不受实时采样改变。读取预算不足时，Hook 切换为独立交替读取状态与事件。

配置、源身份及确认先验证再修改。任务环境收到可用的 S_EVENT_MISSION_END，或处理 Hook 的 shutdown 请求后，注销事件、停止采样，保留可读日志并冻结最终事件序号。Hook 进入 draining，分页读取到 finalEventSeq，不自动 ACK。结束回调默认最多 128 批、0.25 秒 CPU 时间预算，分别由 stopDrainMaxBatches 和 stopDrainBudgetSec 配置；后续按 pollHz 最多补拉 4 批、0.01 秒。达到预算、队列满、请求失败时保留 draining；环境仍可访问且有容量时继续。lifecycle/status 的 sessionEnd 输出 tailComplete 和 tailReason，环境先销毁时不得报告收齐。tailComplete 表示事件/缺失区间已连续读到最终序号，不表示没有发生过缓存溢出，也不代表服务器已确认。

0.2.1 在结束后收到服务器 ACK 时立即尝试仅转交确认，失败后每秒重试，连续失败三次停止；明确的采集器消失/源变化立即停止。不会重新注入旧采集器或把旧 ACK 送给新任务。actualAck 只更新为经过身份验证的采集器响应；collectorAck.state 分别显示 waiting_server、pending、confirmed、unverified。结束元数据随确认变化重新发送，healthFresh=false 标明最后健康度是历史观测。完整字段与服务器显示语义见 [网络协议](../protocol/hook-server-v1.md)。

## 3. 本地验证

DCS 部署只依赖一个生成的 Lua 文件。以下 Python/Lupa 仅用于开发测试和打包。

在项目根目录运行：

```powershell
python -m pip install --target .tools/python -r requirements-dev.txt
python tests/run.py
python tests/run.py --runtime luajit21
python -m unittest discover -s tests -p test_package.py
python tools/smoke.py
python tools/smoke.py --runtime luajit21
python tools/smoke.py --host-io-no-results
python tools/smoke.py --diagnostic-failure-after-write
```

运行时分别使用 Lua 5.1 和 LuaJIT 2.1。测试模拟 DCS 对象、事件、定时器和隔离执行环境，实际执行项目 Lua 源文件，不通过 Python 重写业务逻辑。

smoke 会重新打包，每次在 `runtime/single-file-smoke/run-N/profile` 创建全新的模拟 DCS 配置目录，仅放入一个生成的 Hook 文件。它禁止 Hook 使用外部模块/源码加载，只允许访问诊断输出目录，并验证：注入、飞机最低字段、导弹发射者/目标、非自动确认、显式确认后的日志释放，以及 JSON 输出可被独立解析。结果位于该 profile 的 `Logs/DcsEsport`；不删除旧结果。

smoke 自身是离线模拟，只写项目 runtime，不连接 DCS，也不修改实际 DCS 配置或安装目录。实际部署通过安装步骤单独执行；首轮游戏内采集记录与修正说明见第 9 节。

行为测试覆盖原有采集与确认逻辑；构建测试另外检查单文件布局、源码长字符串边界和清单哈希。单文件入口离线 smoke 输出 `singleFileDeploymentVerified` 及 `externalSourceReads`，明确是否没有读取配套源码。所有这些均不等于 DCS 实机验收通过。

## 4. 打包与安装

先生成部署包：

```powershell
python tools/package.py
```

输出布局：

```text
dist/DcsEsport/
  manifest.json
  Scripts/Hooks/DcsEsportHook.lua
```

只需将生成的 [DcsEsportHook.lua](../../dist/DcsEsport/Scripts/Hooks/DcsEsportHook.lua) 复制到实际比赛服务器配置目录的 `Scripts/Hooks`。manifest.json 是构建校验信息，不需要部署。也可使用安装脚本；下面路径须替换为实际使用的 DCS/DCS.openbeta/服务器配置目录：

```powershell
.\tools\install.ps1 -SavedGamesPath 'C:\Users\你的用户名\Saved Games\DCS'
```

脚本只复制一个生成的 Hook，替换同名 Hook 文件，不修改 MissionScripting.lua，不删除已安装目录。旧版安装留下的模块/config.lua 不再读取，也不由脚本自动删除。安装后重启 DCS。不要另将开发模块放进 Hooks。

需要修改配置时，编辑生成 Hook 顶部 `BEGIN CONFIG` 与 `END CONFIG` 之间的表，然后部署并重启 DCS。要让配置在未来重新构建时保留，应修改项目的 `config/hook.example.lua` 后重新运行打包命令；重新打包会覆盖生成文件中的临时修改。无需额外配置文件。

若目标 DCS 版本限制跨环境接口，先检查 dcs.log 的具体错误和对应版本说明；部署脚本不会自动修改沙箱/白名单配置，也不假定某份历史版本配置始终适用。

## 5. 查看输出

默认目录为实际 Saved Games 配置下的 `Logs/DcsEsport`：

| 文件 | 内容 |
| --- | --- |
| `initialized.json` | 实际采集配置、能力、覆盖范围和源身份 |
| `latest-state.json` | 最近完成的完整快照，默认最多每秒落盘一次；含 aircraft/missile 实体 |
| `events.jsonl` | 按批次追加的事件和缺失区间，每行含源身份 |
| `status.json` | Hook 阶段、路线、读取位置、确认位置、待确认队列和健康度 |
| `lifecycle.jsonl` | 任务尾部完整性和采集器中断记录 |

DCS 日志中使用 `DCS-ESPORT` 标签。首次需要确认 status 从 probing/installing/initializing 进入 collecting；collector 自身 status 可能因字段不可用为 degraded，需要检查 issues。

诊断 JSON 文件是普通覆盖写，外部读取时可能正好碰上写入；解析失败应稍后重试。Hook 内的快照提交是完整后的替换，但不声称磁盘诊断文件具有原子更新或 fsync 保证。

0.1.2 将 Recorder 从接收端 `deps.sink` 移到非阻断的诊断观察器 `deps.observer`。事件通过协议校验并进入 Hook 内存待确认队列后推进 `readThrough`，随后仅尝试一次诊断输出；诊断返回 false 或抛异常均不回退游标、不触发重读或重新探测，不修改 ACK。文件操作及回读校验实现保留，其结果只影响诊断错误报告。`status` 新增 `diagnosticErrorCount` 和 `lastDiagnosticError`，与采集链路的 `lastError` 分开。

可选 `deps.sink` 留给实际接收适配器，其拒收仍会阻止接受该批次。默认单文件入口没有网络接收适配器，仅由 Hook 内存队列接收。诊断失败时文件可能缺少事件，不能将这些文件当作完整或可靠的事件存储。

事件日志允许跨 Hook 重启出现重复；消费者必须使用源身份与 eventSeq 去重。不要仅按同一 simTime 或玩家名称去重。输出中可能包含玩家名称，应按比赛资料管理。

## 6. 受控验证 ACK

0.2.0 已提供 [C++ 网络接收端](server.md)。通用 Hook 包默认关闭网络；配置启用后，合法的 memory ACK 自动转交 Collector。诊断落盘成功不会删除任务日志。关闭网络且长期不确认时，先达到 Hook 背压，再可能达到任务日志上限；溢出通过 gap 和 health 明确报告。以下手工确认步骤仅用于独立采集器测试。

### 6.1 Lua 接收适配器接口

`Bridge:confirm(source, sequence)` 用于未来接收适配器转交确认：

- source 必须含当前任务或保留队列对应的 missionSessionId 和 collectorEpoch。
- sequence 不能超过 Hook 已接收的 readThrough。
- 重复确认不回退。
- 后续 exchange 将确认送回任务环境，并以 actualAck 显示实际结果。

当前源确认会在后续 exchange 转交；保留的旧源确认只释放它自己的 Hook 队列，绝不发送给新任务环境。`getRetainedSessions()` 列出旧源及其读取位置、待确认数和结束结果；`getPendingBatches(source)` 返回指定源的批次，不传 source 时返回当前源。旧源全部释放后不再保留其确认上下文，再次提交将被拒绝，不能影响新任务。

实例名 `DcsEsportHookBridge` 位于当前 Hook 的隔离环境中，不假设其他 Hook 或任务脚本可以直接访问它。未来网络接收器应作为 bridge 依赖/同一 Hook 内的适配器接入。

### 6.2 手工确认文件

仅用于主动执行的本地测试：在单文件 Hook 顶部配置表中设置 `manualAckEnabled=true`，重启 DCS。确认已保存需要的事件后，读取 status.json 的 source 和 readThrough，在同一输出目录写 `manual-ack.json`：

```json
{
  "missionSessionId": "从当前 status.json 复制",
  "collectorEpoch": "从当前 status.json 复制",
  "ackEventSeq": 3
}
```

示例 3 必须替换为不大于当前 readThrough 的已检查位置，不能用任务日志的 latestEventSeq 代替。Hook 大约每秒检查一次文件，源身份错误或越界会拒绝，文件解析中或格式错误会忽略；文件不自动删除，重复读取幂等。

预期结果：confirmedSeq 前进，随后 actualAck 前进，任务日志计数/字节减少。不得把手工确认或文件 flush 描述为 C++ 持久确认。实机测试结束后关闭 manualAckEnabled；旧任务文件因源身份不符不能确认新任务。

## 7. 接管和任务切换

同一个 Hook 实例的重试自动保留源身份。若另一个新 Hook 实例发现已有采集器，默认输出 SOURCE_VERIFICATION_REQUIRED 并保留现有采集器。只有确认当前任务与旧源相同后，才在文件顶部配置中显式设置 resumeSource；不会靠任务名字判断。

当前没有实现 C++ 的持久源身份握手或从诊断日志自动恢复网络发送。resumeSource 只用于受控接管；已有采集器配置必须与请求的 collector 配置一致，否则返回 CONFIG_CONFLICT。

任务结束后，启用的诊断日志文件按源身份保留。新任务使用独立的当前队列，旧任务已接收但未确认的批次保留在 Hook 内存中，按源身份单独读取和确认，共用总容量上限。`totalPendingItems`、`totalPendingBytes` 和 `retainedSessionCount` 展示总占用。环境切换时尚未补拉的尾部报告 mission_environment_replaced；这些未取得的数据无法从新任务环境补回。0.2.0 已支持保留批次跨任务网络重发；进程退出后的持久恢复仍未实现。

## 8. DCS 实机验收顺序

1. 使用最小测试任务，至少包含一架玩家飞机、一架 AI 飞机以及可用空空导弹；准备一个可被查询的目标。
2. 检查 dcs.log 与 initialized.json，验证真正任务环境、返回路线和重复初始化不会增加处理器。
3. 检查速度数值与口径、油量变化、武器初始类型及数量、玩家/AI 标记。
4. 发射两发同型导弹，确认独立 ID、发射平台、发射时玩家名和目标对象。
5. 检查目标无返回/变化/失效、导弹结束、飞机重生、玩家换人及投弃/补给后的数据。
6. 启用一次手工确认测试，验证读取不删除、正确确认清理、旧源和越界确认被拒绝。
7. 测试暂停、任务重开、任务结束和降低缓存上限后的 gap；再按比赛规模测量执行耗时与内存。

当前未给出实机通过结论；特别是燃油外挂口径、空弹药返回、机型武器描述、多人座席、目标查询及结束回调仍以实机结果为准。

## 9. 2026-10-16 首轮实机日志检查

环境为 DCS 2.9.30.28738。Hook 已加载并成功注入；最后完整快照包含 12 架飞机和 10 枚导弹，飞机速度/燃油/武器/占用块均为 ok，导弹发射者均为 known。此次快照中的飞机均为 AI，不据此声称玩家座席已实机验证。

发现并处理的两类问题：

1. 诊断文件存在内容，但旧文件写入结果判定返回失败。读取位置停在 0，106 批日志累计 9585 份事件副本，实际上只有 128 个不同序号。修正兼容判定并补充阶段错误详情；宿主缺少成功返回值时仅在回读字节一致后接受，具体实机返回形态仍需新日志确认。
2. 原生对象被不同 Lua 包装表表示时，旧注册方式可能不断生成引用 ID，并因武器/单位枚举重叠误分类。改用运行时句柄优先关联，武器先按 Object.Category 分类，匿名无身份对象不制造变化事件。

原始日志不清空、不改写。0.1.1 增加针对这两类行为的回归测试，并使用安装目录自带的 luae.exe 运行纯 Lua 测试；这不等于已在游戏内验证修正版。

## 10. 0.1.1 实机复测与 Hook 0.1.2 修正

第二轮按 missionSessionId 单独统计：30 批事件的 afterSeq 均为 0，2652 份副本只有 128 个唯一 eventSeq；相同序号的事件内容全部一致。events.jsonl 有 30 条写入结果校验错误。当前证据说明同一缓存前缀被重复读取并追加，不能据此推断 onEvent 重复触发。

根因是诊断 Recorder 的成功结果被用作 Hook 接收事件的前提：实际文件有内容，但校验返回失败，批次未进入 pending，readThrough 不推进，下一次又请求 afterSeq=0。ACK 为 0 本身不会造成重复读取，读取位置与确认位置是独立的。

Hook 0.1.2 只解除这一耦合，不调整任务事件生成或目标身份逻辑。新增回归模拟“字节已写入但结果校验失败”，验证每个事件只尝试一次诊断输出、内存接收位置正常前进、ACK 保持 0；队列满时仍背压，显式确认后继续读新事件。相同故障的单文件 smoke 也检查每个 eventSeq 仅有一份文件副本。实机仍需重新加载 Hook 验证。

0.1.1 复测中另一项问题是：runtimeObjectId=16777472、dcsObjectId=17 的对象被移除后，导弹继续返回其引用，采集器反复分配新 entityId。这些记录具有不同 eventSeq，属于错误生成变化事件，与同一 eventSeq 被重读是两种问题。0.1.2 未改动该逻辑，0.1.3 的修正见下节。

## 11. 0.1.3 职责划分及修正

目标身份和武器分类完全在被注入的任务采集器中处理；Hook 不持有 DCS 对象、不重新推断它们的身份或类别。

- 对象退出活跃采集后，保存最近 8192 条有界历史身份及最后一次 ObjectRef。死对象的新包装引用、迟到的 hit/kill/unit_lost 复用旧 entityId；历史引用标 object_retired，旧玩家观察标 stale。只有明确存活的替代对象才能获得新生命周期 ID。历史被淘汰时报告 identity_history_evicted，未知死引用不会创建新实体。
- 一般事件的 weapon 按 Weapon.Category 分类为 missile/bomb/rocket/shell/torpedo，无法判定时为 weapon；不再强制标 missile。这不扩展导弹运动跟踪范围。
- 任务环境主动结束与 Hook 停止请求使用同一个幂等 shutdown，输出停止原因和稳定最终序号。Hook 分页补拉、遇限保留进度、重试不回退读取位置；任务切换保留已经接收的旧源数据。

新增回归覆盖死目标包装对象、迟到事件、句柄复用后的新旧身份隔离、历史上限、武器枚举重叠/未知分类、任务环境主动结束、350 条积压分页、时间及批次预算、缓存满后确认续拉、停止响应丢失、环境不可用、跨任务保留与确认隔离、缓存溢出区间。Lua 行为测试共 66 项。单文件 smoke 同时验证目标身份、炸弹命中分类、350 条结束补拉、诊断失败不导致重复副本。以上均为离线测试，尚未声称实机通过。


## 12. 0.1.4：1 Hz 与预编码

- 飞机运动、导弹运动/目标、慢字段默认均为 1 Hz（仿真时间），Hook 正常拉取为 1 Hz（真实时间）。对象列表核对继续每 5 秒执行。注入阶段快速推进，任务结束补拉继续使用有界分页循环，不受正常轮询间隔限制。
- onEvent 仍即时冻结事件，并同时保存完整 JSON 与编码字节数。读取、重读、响应长度校验和最终序列化复用此 JSON，不再递归编码事件正文。ACK、溢出淘汰同步释放记录及编码引用；字节预算仍表示编码量，不宣称等于 Lua 实际内存。
- 每次新快照按 entityId 合并对象属性：飞机含 identity、motion、fuel、armament、occupancy、condition；导弹含 motion、launch、targetObservation、lastKnownTarget 等。整条对象记录不可拆到不同分页。读取返回 data.state 与 data.eventLog；超出响应预算时保留原有分页/分离读取行为。旧事件的发生时快照与当前对象属性保持各自时间戳，不能混为同一时刻。
- 冻结的状态记录与状态页也复用编码结果，分页计量与最终响应不重复递归编码这些记录。缓存仅接收本地编码器产生的 JSON，外部请求不能注入 JSON 片段；弱键缓存随快照/临时响应回收。
- 诊断状态与快照文件按尝试时间限频到每秒一次，失败不再使限频失效。结束状态允许强制写入；诊断仍不构成 ACK。
- 1 Hz 会降低轨迹与目标变化的时间分辨率：一秒内出现又消失的目标变化可能不被轮询观察到；onEvent 的发射、命中等事件不受此限频丢弃。0.1.4 当时尚未接入 C++；0.2.0 的网络接入见 [服务器说明](server.md)，网页仍未实现。


### 0.3.2 状态栏功能移除

单文件 HOOK 已移除 camera/camera_gui 模块及原生状态栏读取、透明度修改和视角命令。任务采集器、玩家连接记录、1 Hz 传输、事件确认和任务结束处理保持原链路。无需安装额外的状态栏探针；替换后重启 DCS 加载新版本。
