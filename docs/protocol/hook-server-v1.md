# Hook → C++ 网络协议 v1

实现版本 0.2.0，日期 2026-10-16。适用于本机单实例 Hook 接入；导播登录、WebSocket 和网页不在本次实现内。实体及事件正文继续使用 [任务环境协议 v1](mission-hook-v1.md)。

## 1. 帧和公共字段

TCP 默认 `127.0.0.1:9081`。每帧为 **4 字节无符号大端长度 + UTF-8 JSON**，长度不含帧头，范围 1～524288 字节。TCP 拆包/粘包不改变消息边界。数值序号是 0～9007199254740991 的整数；身份 ID 是非空字符串，最多 256 字节。

| 字段 | 方向 / 类型 | 规则 |
| --- | --- | --- |
| `transportVersion` | 双向 / integer | 固定 1，与 mission 的 protocolVersion 独立 |
| `type` | 双向 / string | 下表定义的消息类型 |
| `connectionId` | 双向 / string 或 null | hello 为 null；之后必须使用 welcome 分配的连接 ID |
| `serverEpoch` | 服务 → Hook / string | 每次服务进程启动生成，Hook 必须验证 |
| `ackMode` | 服务 → Hook / string | 固定 `memory`，Hook 必须验证 |
| `source` | 源消息 / object | `{instanceId, missionSessionId, collectorEpoch}`；hello/welcome/ping/pong 无此字段 |
| `payload` | 双向 / object | 对应消息的正文 |

`instanceId` 必须与服务器配置及凭据绑定；其余两个 ID 沿用采集器身份。事件键为完整 source 加 eventSeq，实体键为完整 source 加 entityId。每个已认证实例只有一个有效连接，新握手使旧连接失效。服务收到旧连接后续消息即关闭它。

当前协议不含 messageId：事件响应以 source+累计序号关联，结束响应完整回显元数据。协议错误、越界、冲突或错误凭据均记入服务错误日志并关闭连接，不推进错误批次的 ACK；没有网络 error 消息。HTTP 查询另有 JSON 错误响应。

## 2. 消息定义

| type | 方向 | payload |
| --- | --- | --- |
| `hello` | H → S | `instanceId:string`、`token:string`（32～256 字节）、`ackMode:"memory"` |
| `welcome` | S → H | `maxFrameBytes:524288`；连接身份、serverEpoch、ackMode 在外层 |
| `source_open` | H → S | `confirmedSeq:integer`、`readThrough:integer`，前者不得大于后者 |
| `source_ready` | S → H | `ackEventSeq:integer`、`historyIncomplete:boolean` |
| `events` | H → S | `afterSeq`、`throughSeq`、`latestEventSeq`、`events:array`、`gaps:array`，沿用 Bridge 的已验收批次 |
| `ack` | S → H | `ackEventSeq:integer`，表示该源连续接收水位 |
| `snapshot` | H → S | 见下节，按完整实体分页 |
| `status` | H → S | Bridge.getStatus() 原始状态对象，常规每秒一次，结束确认状态改变时立即更新；最大 32 KiB |
| `session_end` | H → S | `latestEventSeq:integer或null`、`readThrough`、`confirmedSeq`、`actualAck`、`pendingItems`、`tailComplete:boolean`、`tailReason:string`、`collectorAck:object` |
| `session_end_received` | S → H | 完整回显已保存的 session_end payload；不等于事件 ACK |
| `ping` / `pong` | H → S / S → H | 空对象 `{}`；5 秒心跳，15 秒无服务响应则重连 |

注意结束消息字段实际名为 **latestEventSeq**；Bridge 状态里的 `finalEventSeq` 表示同一最终水位。null 表示未取得最终水位，不能宣布结束数据齐全。

### 2.1 快照

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `snapshotId` | string | 同一 source 内快照 ID |
| `pageIndex` / `pageCount` | integer | 从 0 开始 / 总页数，最多 64 页 |
| `assembledSimTime` | number | Bridge 组装的仿真时间，不是网络收到时间 |
| `eventSeqAtCapture` | integer | 快照的事件边界，不用于 ACK |
| `scopeRevision` | integer | 采集范围版本 |
| `coverage` | object | 原始采样覆盖信息 |
| `entities` | array | 完整 aircraft/missile 记录；不拆开一个实体的属性 |

同组页必须按页号到达且 ID、页数、仿真时间、事件边界一致。收齐后原子替换最新状态，重复 snapshotId 不增加计数，较早仿真时间不覆盖新快照。未完成的快照不对查询端可见；新第 0 页替换旧暂存。组装总量最多 8 MiB，超过 10 秒后到达的续页被拒绝；暂存随后由新第 0 页重建。

单实体最多 32 KiB。飞机保留 `motion`（速度）、`fuel`（油量）、`armament`（当前武器）、`occupancy`（玩家）与 `identity`；导弹保留 `motion`、`launch.launcher`、`targetObservation` 与 `lastKnownTarget`。未知值、质量标志和观察时间原样保留。

### 2.2 事件批次

单批事件与 gap 合计最多 512 项，单事件最多 32 KiB。所有 eventSeq 与 gap 区间必须恰好、不重叠地覆盖 `(afterSeq, throughSeq]`，满足 `afterSeq <= 服务水位` 和 `throughSeq <= latestEventSeq`。不能跳过未声明的序号；已知最终水位之后的事件被拒绝。

先校验整个批次，再更改仓库和返回 ACK。保留范围内同序号、同 JSON 值是重发，只增加 duplicateEvents，不增加 acceptedEvents；不同内容或事件/gap 冲突拒绝。已经按容量策略淘汰的旧序号仅按水位忽略，不再承诺正文核对。

## 3. memory ACK 与恢复

ACK 表示数据或显式缺失事实已进入**当前 C++ 进程的权威内存仓库**。它允许 Bridge.confirm 和任务采集器释放对应日志；不表示写盘，也不保证服务进程退出后的恢复。`durable` 模式未实现，不能配置或宣称支持。

1. hello → welcome，建立 connectionId/serverEpoch/ackMode 绑定。
2. 对当前源及保留旧源分别 source_open → source_ready。
3. 服务已有该源时返回原接收水位；Hook 只接受不超过自身 readThrough 的值。旧连接或不匹配 source 的确认不能释放队列。
4. 服务没有该源时，以 Hook 的 confirmedSeq 为恢复基线；若大于 0，则记录 `[1, confirmedSeq]`、reason=`server_restart_or_new_receiver`，并设 historyIncomplete。不能要求已经 ACK 的 Collector 倒退。
5. Hook 从 pending 批次重发，每源至多一批等待 ACK；5 秒未确认则断线恢复。相同 ACK 幂等，较小值不倒退确认。
6. 当前任务的确认通过下一次 1 Hz exchange 送回 Collector；任务结束后收到 ACK 时立即尝试仅转交确认，不请求对象状态或事件。失败后间隔至少一秒重试，连续失败三次停止；明确返回 SOURCE_CHANGED/COLLECTOR_ABSENT 时立即停止。旧环境已被替换时，确认只释放旧 Hook 队列。重试成功重置连续失败数。

重连退避 0.5→1→2→4→8→10 秒，成功后重置。socket timeout=0，无阻塞等待和 DNS。帧回调每次接收/发送各至多 64 KiB、4 帧，共用约 1 ms CPU 检查预算；单次 JSON 编码/系统调用不能被该预算抢占，仍须游戏内测量。网络泵不增加任务采样频率。

## 4. 任务结束

任务环境冻结最终日志，Bridge 按原有有界预算补拉；网络按源公平发送 pending，并独立重传结束元数据。结束回调只做最多 10 ms 的无等待收发推进，后续依赖 DCS 帧/生命周期回调继续。若 DCS 不再提供回调或退出进程，不能保证剩余数据送出；不在停止回调里等待服务器。

服务分别提供：

- `sessionEnd.tailComplete`：Hook 是否读到最终水位。
- `serverTailComplete`：已收到结束元数据且服务 receivedThrough 达到最终水位。
- `historyComplete`：serverTailComplete 且没有已知采集/重启缺口；不表示所有历史永久保留。保留窗口另看 historyStart。
- `collectorCleanupComplete`：采集器实际返回的 ACK 已到最终水位。与服务器收齐独立；false 不能据此判定服务器丢事件。
- `collectorAck`：优先读取最新 sessionEnd 的清理状态；尚无结束元数据时读取 hookStatus。同一源结束确认变化会重新发送 session_end，旧回显不能确认新版本。

`collectorAck` 字段：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `state` | string | `running` 尚无最终水位；`waiting_server` 等服务器确认尾批；`pending` 等采集器确认；`confirmed` 采集器已确认最终水位；`unverified` 已停止尝试，未验证清理结果 |
| `targetSeq` | integer/null | 最终事件水位；未知为 null |
| `confirmedSeq` | integer | HOOK 已验证的服务器 ACK |
| `actualAck` | integer | 最近一次采集器明确返回的 ACK，失败时不推测或递增 |
| `attempts` | integer | 任务停止后仅转交 ACK 的调用次数 |
| `consecutiveFailures` / `retryLimit` | integer | 连续失败次数 / 上限 3 |
| `lastError` | string/null | 最近失败原因；环境替换为 mission_environment_replaced；成功后清空 |

任务结束后 `hookStatus.healthFresh=false`，`health` 仅保留最后观测，不能把其中 eventBufferCount 当成仍存活环境的实时积压。`healthObservedAt` 是 HOOK 时钟的观测秒数，非 UTC。环境消失或返回路径不可用时，`unverified` 表示无法确认清理，不代表事件未进入服务器。`actualAck` 和最后观测仍保留用于诊断。若 DCS 不再调用 HOOK，状态可能停留在 pending/waiting_server；不能宣称有独立后台计时器完成重试。

旧源 ACK 与新源隔离。已确认结束元数据可在同一 Hook 生命周期内重发给重启后的服务器；结束缓存最多 64 个，先淘汰已确认项，全为未确认时明确报错。0.3.0 服务器保留最多 64 个完整源；容量满时，将已结束且服务器接收水位已被 HOOK 确认的最旧源转为紧凑记录。最多保留 128 个紧凑记录，用于恢复确认和展示结束状态，不再保留快照及事件正文。未结束、未确认的源不会被淘汰；全为此类源时明确拒绝新源。本期不做无限期赛事归档。

## 5. 只读诊断 HTTP

默认 `127.0.0.1:9080`。除 healthz，其余均要求 `Authorization: Bearer <apiToken>`，与 Hook token 分开。只接受 GET；无网页、登录会话或 WS 接口。

| 路由 | 响应 |
| --- | --- |
| `/healthz` | status、version |
| `/api/v1/status` | serverEpoch、ackMode、connections、frames、protocolErrors、eventBytes |
| `/api/v1/sources` | 源身份、水位、接收/重复数、保留范围、快照数、gap、结束状态、Hook 状态 |
| `/api/v1/sources/{id}/snapshot` | `{source, state}`，未完成首帧时 state=null |
| `/api/v1/sources/{id}/events?afterSeq=N` | 最多 128 条、约 512 KiB 正文预算的 events，以及 receivedThrough、gaps；无 limit 参数 |

事件查询只读，不影响上游 ACK。下一页用返回 events 的最后 eventSeq；有 gap 时参照 gaps 跳过明确缺失区间。游标早于保留窗口返回 409/resync_required。每源历史最多 10000 条或 16 MiB，全局事件正文预算 64 MiB；这些是编码量，不是进程 RSS 上限。多个查询客户端共享同一份采集数据，不触发新的 DCS 采样。

配置及实测步骤见 [服务器运行说明](../implementation/server.md)。

## 6. 协议拒绝日志（0.2.1）

每次增加 protocolErrors 均向 stderr 输出一行 JSON：event=ingress_rejected、timestampUtc、serverEpoch、ingressId（TCP 接入序号，包括未认证连接）、peerAddress、peerPort、localPort、authenticated、connectionId（认证前为 null）、stage（header/json/protocol）、reason、declaredLength、headerHex（四字节头）、protocolErrors（累计数）。认证后额外记录 instanceId。

日志不包含正文、令牌或任意消息字段。HTTP `GET ` 错投 TCP 时，可见 headerHex=47455420、declaredLength=1195725856、stage=header、reason=frame_too_large；这只能证明收到该头，不能据此推断客户端进程名。普通连接关闭、读超时不计为协议拒绝。

## 7. 0.3.0 新鲜度、结束失败与容量语义

常规新快照仍以 1 Hz 开始拉取。后续页读取已冻结的数据，按帧最多推进 4 页、约 2 ms 的调用前检查预算；不增加任务采样次数。事件/结束帧先获得发送机会，连续数据帧最多推迟到期控制消息 4 帧；快照不能阻挡状态和 ping。预算不能抢占单次 Lua/JSON 操作。

结束补拉连续三次读取失败后退出 draining，保留 tailComplete=false、最后错误和已取得的最终水位（未知仍为 null）。明确 SOURCE_CHANGED/COLLECTOR_ABSENT 可立即结束。队列满属于背压，不作为环境失效累计失败。session_end 新增 captureClosed:boolean，表示该采集会话不再继续读取；它与 tailComplete 独立。

`/api/v1/sources` 新增：

| 字段 | 语义 |
| --- | --- |
| online | 源绑定的 HOOK 连接仍有效且最近源消息不超过 15 秒；不是进程探测 |
| statusFresh | online 且最近状态消息小于 3 秒 |
| snapshotFresh | online、未结束、采集未关闭且最近完整快照小于 3 秒 |
| receivedAgeSec / statusAgeSec / snapshotAgeSec | 服务器单调时钟计算的真实秒数；尚无观测为 null |
| lifecycle | running / paused / offline / ending / ended，暂停与断线分开 |
| transportComplete | 最终水位已收齐且没有已知传输 gap；原 historyComplete 保留为兼容别名 |
| captureIntegrity | unknown / complete_since_capture_start / incomplete；由采集连续性、捕获错误、溢出和拒绝记录确定，不代表注入前的历史 |
| historyRetained | 正文未因事件窗口或源归档淘汰；与传输收齐和采集完整性独立 |
| evictedEvents / archived | 被淘汰的正文条数 / 是否只剩紧凑确认记录 |

hookStatus 是最后报告，不能单独依据其 active/healthFresh 判断当前连接存活。hookStatus.exchangeMetrics 提供 calls、lastCpuMs、maxCpuMs，测量 HOOK 发起一次 exchange（包含跨环境请求和响应解码）的 CPU 时间；Windows 时钟精度有限，不是端到端延迟或 DCS 帧时间。

## 状态栏扩展已移除（HOOK 0.3.2 / C++ 0.4.1）

新 HOOK 不再上报 camera，不包含 GUI 状态栏读取、透明度或视角命令。C++ 不维护 cameraControl，也不发送 camera_control。旧 status 作为不透明诊断内容仍可接收，但不会触发控制行为。事件、ACK、玩家在线记录和 1 Hz 周期不变。

## 玩家在线状态扩展（HOOK 0.3.1）

1 Hz `status.players` 随原有 status 发送，C++ 不改变该对象的内容，导播通过 sources[].hookStatus.players 获取。保持单文件 Hook，不改变任务注入、事件序号、ACK 或任务结束补拉。

```json
{"supported":true,"sequence":12,"records":[{"id":2,"name":"Ace","side":1,"slot":"41","connected":false,"generation":1,"disconnects":1,"changed":12}]}
```

`supported` 表示当前网络名单查询是否可用；`sequence/changed` 为 Hook 内名单变化版本；`id` 为 DCS 连接玩家 ID，`name` 为公开名称，`side` 为 DCS 阵营 0/1/2，`slot` 原值转字符串。`generation` 为同名同 ID 的连接代次，`disconnects` 为观察到的断开次数。不发送 IP/UCID。记录最多 256 条，任务开始重置；版本不是任务事件序号。

只有 `onPlayerDisconnect(id)` 将 connected 置 false，空名单、API 异常、玩家离开座位、源超时均不生成断线。查询每秒一次，成功读取该玩家后置 true。断线状态重复发送，可穿越一般网络重连，但不是可靠 ACK 事件日志，快速断线再重进可能只观察到更新后的在线状态。官方 API 指出此回调不会报告本机玩家自身断线；需要观察该选手的远端/服务器 Hook 提供证据。
