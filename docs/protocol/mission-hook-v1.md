# 任务环境与 Hook JSON 协议 v1

状态：协议草案，DCS 实机已产出数据，0.1.3 修正版通过离线回归、待实机复测。文档日期：2026-10-16。部署及实现边界见 [实现说明](../implementation/mission-hook.md)。

配套架构见 [任务环境与 Hook 架构](../architecture/mission-hook.md)。本文中的“必须”用于约束后续实现；JSON 示例为协议数据，不是实现代码。

## 1. 协议边界与最低数据契约

Hook 是唯一请求方，任务采集器是响应方。每次操作使用一个 JSON 请求，返回一个 JSON 响应字符串。DCS 跨环境调用的执行路线、原始返回值及异常均由 Hook 适配层处理，不泄露成业务层的多返回值约定。

### 1.1 不可关闭的最低数据项

配置可以调整频率与范围，但不能静默关闭范围内飞机和被捕获导弹的以下字段：

| 用户需要回答的问题 | 必需字段路径 | 正常结果 | 不可用时 |
| --- | --- | --- | --- |
| 飞机速度多少 | `aircraft.motion.velocity`、`speedMps`、`groundSpeedMps` | 矢量、三维速度及水平地速，单位 m/s | `null` 或最后有效值，加状态和时间 |
| 飞机油量多少 | `aircraft.fuel.ratioRaw` | DCS 燃油 API 原始比例 | `null` 或陈旧值；不能填 0 |
| 飞机有什么武器 | `aircraft.armament.items` | 当前弹药类型、名称、分类和数量 | `null`；不能填 `[]` 冒充空弹药 |
| 是否玩家飞机 | `aircraft.occupancy.isPlayer`、`playerName` | 明确布尔值与可用玩家名 | `null` 或标记陈旧；不能当作 AI |
| 每发导弹谁发射 | `missile.launch.launcher`；`weapon_fired.details.launch` | 发射时平台和玩家快照 | `unknown` 或冲突状态，报告不完整 |
| 导弹目标是谁 | `missile.launch.initialTarget`、`targetObservation`、`lastKnownTarget` | 目标状态及对象身份 | 区分无返回、不可用和陈旧 |

必需字段键始终存在；数据值可以未知。最低字段暂时失败使记录退化，不意味着应丢弃整个实体。持续不可用必须通过 `capabilities` 和 `health` 报告，并在实施验收中处理。

### 1.2 JSON 与类型约定

- UTF-8，标准 JSON；空列表为 `[]`，对象为 `{}`，没有值为 `null`。
- `number` 必须有限，禁止 NaN 和 Infinity；无法规范化时为 `null` 并记录问题。
- `integer` 为非负、安全整数，最大 `9007199254740991`。计数和页码从 0 开始；日志 `eventSeq` 从 1 开始。接近上限时受控建立新 epoch，不能回绕复用。
- DCS ID 使用字符串保存，避免不同语言的整数精度和格式差异。
- 所有 `*SimTime`、事件 `simTime` 均为该任务的仿真秒数。暂停时允许不变，不能用于真实时间网络超时。
- `*Bytes` 按 UTF-8 编码后的字节数限制；日志内存估算单独说明，不与响应长度混用。
- 可空写作 `T | null`；必需键没有成功读数时仍输出该键。
- 未请求的数据块返回 `null`；不知道值也用 `null`，通过对应状态区分。
- 同一主版本可新增可选字段，消费者忽略未知可选字段。未知操作、必需语义或不支持的主版本必须明确报错，不能当正常结果处理。

### 1.3 身份

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `missionSessionId` | string | Hook 分配的一次任务运行身份，重开任务也变化 |
| `collectorEpoch` | string | Hook 为新采集器分配的连续采集段身份；安装重试不变化 |
| `entityId` | string | epoch 内的一次实体生命身份 |
| `eventSeq` | integer | epoch 内单调递增的日志序号 |
| `requestId` | string | 关联请求与响应，不是事件去重键 |
| `snapshotId` | string | 一份冻结的完整状态快照身份 |

实体、事件、快照和游标均限定在同一个 `(missionSessionId, collectorEpoch)` 内，不允许跨 epoch 使用。

## 2. 通用信封

### 2.1 请求

| 字段 | 类型 | 必需 | 定义 |
| --- | --- | --- | --- |
| `protocolVersion` | integer | 是 | v1 固定为 1 |
| `requestId` | string | 是 | 非空请求关联 ID |
| `op` | string | 是 | `probe`、`initialize`、`exchange`、`configure`、`shutdown` |
| `missionSessionId` | string | 除初始 probe 外 | 请求目标任务 |
| `collectorEpoch` | string | 除初始 probe 外 | 请求目标采集器 |
| 其他字段 | 依操作定义 | 依操作定义 | 见各操作 |

`probe` 可不带源身份，用于发现已存在实例；若带了身份，则必须校验。其他操作收到不匹配身份时不能修改任何状态。

### 2.2 成功响应

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `protocolVersion` | integer | 实际响应协议版本 |
| `requestId` | string | 原样回传 |
| `op` | string | 原样回传 |
| `ok` | boolean | `true` |
| `missionSessionId` | string | 当前实例源身份 |
| `collectorEpoch` | string | 当前实例采集段 |
| `data` | object | 操作结果 |

正常协议响应以采集器已注入为前提。尚无采集器时的命名空间探测、短字符串回显和执行异常属于 Hook 安装适配层，不伪造为采集器返回的 JSON。

### 2.3 错误响应

失败时 `ok=false`，无正常 `data`，返回 `error`：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `error.code` | string | 稳定错误码 |
| `error.message` | string | 人可读说明，不用于程序分支 |
| `error.retryable` | boolean | 原因解除后是否适合重试；不表示应立即忙轮询 |
| `error.context` | object | 状态线索，如实际 ACK、版本或失效游标；可为空对象 |

响应身份为实际实例身份，不盲目回显请求中的错误身份。无法探明身份的安装层错误由 Hook 自行封装，不能归属于某个已确认的采集器。

## 3. probe

已安装采集器返回以下 `data`：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `collectorVersion` | string | 实现版本 |
| `status` | string | `installed`、`initializing`、`ready`、`degraded`、`stopped` |
| `collectorSimTime` | number | 当前仿真时间 |
| `configRevision` | integer | 尚未初始化为 0 |
| `scopeRevision` | integer | 尚未初始化为 0 |
| `ackEventSeq` | integer | 已确认日志位置 |
| `latestEventSeq` | integer | 当前日志末端 |

探测只读，不复位缓存、序号、定时器或确认位置。Hook 接管前检查发现的源身份和版本。

## 4. initialize

### 4.1 请求配置

除信封外必须提供 `config`。初始 `revision=1`。

| 字段 | 类型 | 默认/约束 |
| --- | --- | --- |
| `config.revision` | integer | 初始为 1 |
| `config.scope.coalitions` | string[] | 默认 `red`、`blue`、`neutral`；不允许重复 |
| `config.scope.includeAirplanes` | boolean | 默认 true |
| `config.scope.includeHelicopters` | boolean | 默认 false |
| `config.scope.missileScope` | string | `all` 或 `air_launched`；默认 all，作用于所选阵营 |
| `config.sampling.aircraftHz` | number | 默认 1，必须大于 0 |
| `config.sampling.missileHz` | number | 默认 1，必须大于 0 |
| `config.sampling.slowFieldsHz` | number | 默认 1，必须大于 0 |
| `config.sampling.reconcileIntervalSec` | number | 默认 5，必须大于 0 |
| `config.eventBuffer.maxCount` | integer | 默认 10000，必须大于 0 |
| `config.eventBuffer.maxBytes` | integer | 默认 16777216，必须大于 0 |

`slowFieldsHz` 包括燃油、弹药、占用和生命值。导弹目标查询与导弹运动使用 `missileHz`。频率按仿真时间调度。实现可以设安全上限，但任何调整都必须通过 `acceptedConfig` 返回，不能假装按原值采样。

`all` 不把“飞机遥测是否纳入”作为导弹发射者过滤条件，允许捕获所选阵营中的地面发射导弹。`air_launched` 仅保留空中平台发射的导弹，会缩小覆盖范围，必须明确报告。

请求示例：

```json
{
  "protocolVersion": 1,
  "requestId": "req-init-1",
  "op": "initialize",
  "missionSessionId": "mission-20261016-a",
  "collectorEpoch": "collector-1",
  "config": {
    "revision": 1,
    "scope": {
      "coalitions": ["red", "blue", "neutral"],
      "includeAirplanes": true,
      "includeHelicopters": false,
      "missileScope": "all"
    },
    "sampling": {
      "aircraftHz": 1,
      "missileHz": 1,
      "slowFieldsHz": 1,
      "reconcileIntervalSec": 5
    },
    "eventBuffer": {
      "maxCount": 10000,
      "maxBytes": 16777216
    }
  }
}
```

### 4.2 初始化结果

| `data` 字段 | 类型 | 定义 |
| --- | --- | --- |
| `collectorVersion` | string | 实现版本 |
| `status` | string | ready 或 degraded；尚未完成时返回 NOT_READY，不返回假就绪 |
| `configRevision` | integer | 当前配置版本 |
| `scopeRevision` | integer | 初始为 1；只有范围变化才递增 |
| `acceptedConfig` | object | 完整实际配置，结构同请求 config |
| `captureStartedSimTime` | number | 开始接收事件的时间 |
| `baselineCompletedSimTime` | number | 初始扫描完成时间 |
| `capabilities` | object | 下面定义的能力 |
| `coverage` | object | 下面定义的覆盖范围 |
| `eventLog.ackEventSeq` | integer | 已确认位置 |
| `eventLog.latestEventSeq` | integer | 当前末端 |
| `limits.maxResponseBytes` | integer | 实例允许的响应硬上限，初始建议 262144 |
| `limits.maxRecordBytes` | integer | 单条规范记录上限，初始建议 32768 |

`capabilities` 各键均为必需布尔值：`aircraftMotion`、`aircraftFuel`、`aircraftArmament`、`playerOccupancy`、`missileTracking`、`weaponLauncherQuery`、`weaponTargetQuery`。它们表示接口路径可用，不保证每个对象每次都有读数。`weaponLauncherQuery=false` 时仍可从事件发起者取得发射者。

`coverage` 定义：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `aircraft` | string | v1 为 `initial_scan_and_events` |
| `missiles` | string | v1 为 `shots_since_capture_start` |
| `events` | string | v1 为 `since_capture_start` |
| `continuous` | boolean | 从本 epoch 的捕获起点开始是否已知连续；重建不能因此声称覆盖整个任务 |
| `issues` | string[] | 已知能力/覆盖问题；正常为空 |

重试相同初始化返回当前实例及其当前日志位置。配置版本相同但内容不同返回 `CONFIG_CONFLICT`，不同版本的修改走 `configure`。已停止实例不能通过重复初始化清空日志并重新运行。

## 5. exchange

### 5.1 请求

| 字段 | 类型 | 必需/默认 | 定义 |
| --- | --- | --- | --- |
| `ackEventSeq` | integer | 否 | 提交 C++ 的连续确认位置；省略则不推进 |
| `read.state.enabled` | boolean | 是 | 是否读取状态页 |
| `read.state.cursor` | string \| null | state 启用时必需 | null 开始新快照；非空读取指定冻结快照页 |
| `read.events.enabled` | boolean | 是 | 是否读取事件 |
| `read.events.afterSeq` | integer | 否 | 从其后一条读取；省略时采用本请求合法 ACK 应用后的实际确认位置 |
| `read.events.maxCount` | integer | 否，默认 128 | 本次日志项上限，建议允许 1～512；每个事件或缺失区间算一项 |
| `limits.maxResponseBytes` | integer | 否，默认实例上限 | 请求更小的响应预算，不能超过实例硬上限；v1 建议最小 65536 |

可以仅 ACK，或仅读取某一种数据。禁用 state 时不使用 cursor；禁用 events 时不使用 afterSeq/maxCount。Hook 串行发起跨环境请求，避免两个消费者同时替换同一份冻结快照。

请求示例：

```json
{
  "protocolVersion": 1,
  "requestId": "req-exchange-520",
  "op": "exchange",
  "missionSessionId": "mission-20261016-a",
  "collectorEpoch": "collector-1",
  "ackEventSeq": 1200,
  "read": {
    "state": {"enabled": true, "cursor": null},
    "events": {"enabled": true, "afterSeq": 1200, "maxCount": 128}
  },
  "limits": {"maxResponseBytes": 262144}
}
```

### 5.2 执行与幂等

1. 先验证源身份、版本、参数、游标和 ACK 边界；验证失败不修改确认位置。
2. 应用合法 ACK；删除已确认事件和已确认缺失区间。
3. 构建指定状态页、事件批次和健康度，按预算编码。
4. 记录已交付日志的最高 `throughSeq`，供后续 ACK 边界校验。

ACK 应用后若构建/返回失败，ACK 可能已生效，失败响应尽量在 `error.context.ackEventSeq` 返回实际值。Hook 不能根据缺少成功响应推断 ACK 未执行；重复提交同一 ACK 安全。

读取不删除日志。重试相同读取请求可能得到更新状态或更多事件，不保证整个 JSON 逐字节相同；事件身份、已冻结快照页及确认语义必须稳定。

### 5.3 响应 data

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `collectorSimTime` | number | 响应构建时仿真时间 |
| `status` | string | ready、degraded 或 stopped |
| `configRevision` | integer | 当前配置版本 |
| `scopeRevision` | integer | 当前采集范围版本 |
| `ackEventSeq` | integer | 已实际应用的确认位置 |
| `state` | StatePage \| null | 未请求时为 null |
| `eventLog` | EventBatch \| null | 未请求时为 null |
| `health` | Health | 运行健康度 |
| `finalEventSeq` | integer \| null | 0.1.3 扩展：stopped 时冻结的最终事件序号，运行中为 null |
| `stopReason` | string \| null | 0.1.3 扩展：mission_end_event 或 hook_shutdown，运行中为 null |

`stopped` 实例允许继续读取最后状态、事件和提交 ACK；不会再采样。

## 6. 基础数据类型

### 6.1 Vector3 与 Basis

`Vector3` 必须包含有限数字 `x`、`y`、`z`。位置与速度使用 DCS 本地世界坐标，其中 y 为竖直方向，水平面为 x/z；不把它们直接解释为经纬度。

`Basis` 包含三个 Vector3：`forward`、`up`、`right`，对应对象的机体方向，均在世界坐标中表达。不可读取时整个 Basis 为 null，不生成默认单位矩阵冒充读数。

### 6.2 采样块质量信息

Motion、Fuel、Armament、Occupancy 和 Condition 包含以下公共字段：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `status` | string | `ok`、`partial`、`stale`、`unavailable` |
| `sampledSimTime` | number \| null | 最近有效数据时间；从未成功为 null |
| `lastAttemptSimTime` | number | 最近一次尝试的时间 |
| `issues` | string[] | 字段缺失、未验证换算等规范问题码 |

`ok` 表示本块必需的直接读数有效；未保证的可选增强值为空不必使块退化。例如未启用燃油质量换算时，比例有效的 Fuel 可以为 ok，但 issues 仍说明换算未验证。

`partial` 表示部分本次字段可用，其余字段为 null，不混入无独立时间的旧值。`stale` 表示保留整块上次有效读数；时间仍为上次成功时间。`unavailable` 表示没有可用读数，值字段为 null。暂停产生的自然时间停滞不单独构成读取失败。

### 6.3 ObjectRef

用于历史对象快照、发射者和目标。除标为可选扩展的 runtimeObjectId 外，以下键全部必需：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `entityId` | string \| null | 可登记时的系统身份；可以是只有引用而无遥测的实体 |
| `dcsObjectId` | string \| null | DCS 对象标识 |
| `runtimeObjectId` | string \| null | 可选扩展：DCS 原生 id_ 或 getObjectID 的运行时句柄；用于跨 Lua 包装对象关联 |
| `kind` | string \| null | aircraft、missile、ground_unit、ship、static、other；0.1.3 增加 bomb、rocket、shell、torpedo、weapon（武器类别未知） |
| `name` | string \| null | DCS 对象名；飞机为单位名 |
| `typeName` | string \| null | DCS 型号 |
| `coalition` | string \| null | red、blue、neutral；不能判定为 null |
| `isPlayer` | boolean \| null | 快照时可观察的玩家状态 |
| `playerName` | string \| null | 对应玩家名 |
| `occupancyStatus` | string | ok、stale、unavailable、not_applicable |
| `occupancySampledSimTime` | number \| null | 玩家状态实际观察时间 |
| `capturedSimTime` | number | 此引用快照建立时间 |
| `issues` | string[] | 无法读取字段等问题 |

`entityId` 不是引用解析的唯一办法；嵌入的 name、typeName 等字段必须保留，不能只输出一个可能不在当前状态集合中的 ID。非单位对象不适用玩家状态时 `isPlayer=null`、`occupancyStatus=not_applicable`。

0.1.1 实现还在 Aircraft/Missile 顶层提供可选 `runtimeObjectId`。它与 getID 的 `dcsObjectId` 分开：Unit.getID 可能是任务单位 ID，getTarget 可能每次返回新 Lua 包装表。内部注册优先使用原生运行时句柄，不能把包装表地址变化当成目标变化。没有可靠身份的对象明确保留未知，不为每次查询制造新的引用实体。

0.1.3 对已移除对象保留有上限的身份历史与最后一次引用，旧死引用继续返回原 entityId，并增加 object_retired 问题标记；玩家观察时间保持原值，原 ok 状态改为 stale。明确存活的新对象复用旧句柄时获得新 entityId。历史淘汰通过 health.issues 的 identity_history_evicted 明示，未知死引用不重新分配身份。一般事件中的武器分类按 Weapon.Category 判断；类别不可读取时为 weapon，不能推断成 missile。

## 7. 飞机实体 Aircraft

### 7.1 顶层与身份

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `entityId` | string | 本次飞机生命 ID |
| `kind` | string | 固定 aircraft，包含配置启用的直升机 |
| `dcsObjectId` | string \| null | DCS 标识 |
| `discovery` | string | initial_scan、birth_event、reconcile |
| `discoveredSimTime` | number | 本采集器发现时间，不伪装为实际出生时间 |
| `identity` | object | 下列身份字段 |
| `motion` | Motion | 必需 |
| `occupancy` | Occupancy | 必需 |
| `fuel` | Fuel | 必需 |
| `armament` | Armament | 必需 |
| `condition` | Condition | 必需结构，读数允许未知 |

`identity` 的必需键：`unitName`、`groupName`、`typeName`、`coalition`、`countryId`、`aircraftCategory`。前四者为 string|null，`countryId` 为 integer|null，`aircraftCategory` 为 airplane、helicopter 或 null。

### 7.2 Motion

公共质量字段之外，必须包含：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `sampleSeq` | integer \| null | 对应运动采样流序号；飞机流与导弹流不比较大小 |
| `position` | Vector3 \| null | 米 |
| `velocity` | Vector3 \| null | 米/秒，世界坐标速度 |
| `speedMps` | number \| null | `sqrt(vx²+vy²+vz²)`，三维世界速度大小 |
| `groundSpeedMps` | number \| null | `sqrt(vx²+vz²)`，水平地速 |
| `basis` | Basis \| null | 姿态基向量 |
| `inAir` | boolean \| null | API 是否报告在空中 |

速度标量必须由同一有效 velocity 算出；velocity 为 null 时不能输出正常的速度标量。速度口径不等于 IAS/TAS。Motion 被导弹复用时字段相同，不支持的 basis/inAir 可为空并报告 partial。

### 7.3 Occupancy

公共质量字段之外：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `isPlayer` | boolean \| null | 当前可观察的玩家控制状态；未知不等于 false |
| `playerName` | string \| null | 当前玩家名；已知 AI 时为 null |
| `source` | string | v1 正常为 unit_getPlayerName；未建立读数为 unavailable |

成功调用却无玩家的语义须在目标版本确认后才输出 false。名字不是账号唯一键；不承诺多人座席完整性。

### 7.4 Fuel

公共质量字段之外：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `ratioRaw` | number \| null | DCS getFuel 原始比例；保留原值，不强制截断 |
| `source` | string | unit_getFuel 或 unavailable |
| `referenceInternalCapacityKg` | number \| null | 来自机型描述的内油参考容量 |
| `massKgEstimate` | number \| null | 经过验证的换算估算值，未验证为 null |
| `massMethod` | string | unavailable 或 verified_ratio_times_internal_capacity |
| `massValidationId` | string \| null | 启用换算所依据的机型/版本/配置验证记录身份 |

比例有效不表示已知“全油箱剩余百分比”。若经过对应部署条件验证，质量估算可为 `ratioRaw * referenceInternalCapacityKg`；没有验证记录或参考容量时，massMethod 必须为 unavailable，估算及验证 ID 为 null。

### 7.5 Armament 与 AmmoItem

公共质量字段之外：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `source` | string | unit_getAmmo 或 unavailable |
| `items` | AmmoItem[] \| null | 成功查询的当前弹药；已知空为 []，失败为 null |
| `coverage` | string | 固定 api_visible_ammunition |

每个 AmmoItem 的必需字段：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `weaponKey` | string | 类型键，优先 typeName，其次 wsType，未知键不与已知类型合并 |
| `typeName` | string \| null | API 描述中的可靠型号；缺失不能用显示名伪装 |
| `displayName` | string \| null | 可读名称，可能本地化 |
| `category` | string | missile、bomb、rocket、shell、torpedo、other、unknown |
| `count` | integer | 该 API 条目的当前数量，不是本次发射数量 |
| `wsType` | integer[] \| null | 存在时保留原始类型向量 |
| `identification` | string | type_name、ws_type、unknown |

第一版保留各 API 条目，不凭相同显示名合并。`identification=unknown` 时整个 Armament 至少为 partial，保留未知项和计数。count 读取失败的条目不能记作 0；整块标记 partial 并在 issues 报告条目无法规范化。此类失败意味着最低清单未完整满足。

### 7.6 Condition

公共质量字段之外：`exists`（boolean|null）、`lifeRaw`（number|null）、`lifeReference`（number|null）。生命值是原始读数，不直接当作损伤百分比。对象被移除后一般由新完整快照及事件表达，不长期留在活跃集合中。

### 7.7 飞机示例

以下是一个完整 Aircraft 数据记录示例。燃油比例有效但绝对质量换算尚未验证；示例武器类型和数量用于说明协议，不是对某次 DCS 实测结果的断言。

```json
{
  "entityId": "aircraft-17",
  "kind": "aircraft",
  "dcsObjectId": "16777729",
  "discovery": "birth_event",
  "discoveredSimTime": 0.3,
  "identity": {
    "unitName": "Blue-1",
    "groupName": "Blue-Flight",
    "typeName": "F-16C_50",
    "coalition": "blue",
    "countryId": 2,
    "aircraftCategory": "airplane"
  },
  "motion": {
    "status": "ok",
    "sampledSimTime": 125.5,
    "lastAttemptSimTime": 125.5,
    "issues": [],
    "sampleSeq": 1255,
    "position": {"x": 10000, "y": 5000, "z": 20000},
    "velocity": {"x": 240, "y": 0, "z": 70},
    "speedMps": 250,
    "groundSpeedMps": 250,
    "basis": {
      "forward": {"x": 0.96, "y": 0, "z": 0.28},
      "up": {"x": 0, "y": 1, "z": 0},
      "right": {"x": -0.28, "y": 0, "z": 0.96}
    },
    "inAir": true
  },
  "occupancy": {
    "status": "ok",
    "sampledSimTime": 125,
    "lastAttemptSimTime": 125,
    "issues": [],
    "isPlayer": true,
    "playerName": "Pilot-A",
    "source": "unit_getPlayerName"
  },
  "fuel": {
    "status": "ok",
    "sampledSimTime": 125,
    "lastAttemptSimTime": 125,
    "issues": ["mass_conversion_unverified"],
    "ratioRaw": 0.62,
    "source": "unit_getFuel",
    "referenceInternalCapacityKg": null,
    "massKgEstimate": null,
    "massMethod": "unavailable",
    "massValidationId": null
  },
  "armament": {
    "status": "ok",
    "sampledSimTime": 125.46,
    "lastAttemptSimTime": 125.46,
    "issues": [],
    "source": "unit_getAmmo",
    "coverage": "api_visible_ammunition",
    "items": [
      {
        "weaponKey": "type:AIM_120C",
        "typeName": "AIM_120C",
        "displayName": "AIM-120C",
        "category": "missile",
        "count": 3,
        "wsType": null,
        "identification": "type_name"
      },
      {
        "weaponKey": "type:AIM_9X",
        "typeName": "AIM_9X",
        "displayName": "AIM-9X",
        "category": "missile",
        "count": 2,
        "wsType": null,
        "identification": "type_name"
      }
    ]
  },
  "condition": {
    "status": "ok",
    "sampledSimTime": 125,
    "lastAttemptSimTime": 125,
    "issues": [],
    "exists": true,
    "lifeRaw": 100,
    "lifeReference": 100
  }
}
```

## 8. 导弹实体 Missile

### 8.1 顶层

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `entityId` | string | 每发独立 ID |
| `kind` | string | 固定 missile |
| `dcsObjectId` | string \| null | 导弹 DCS 标识 |
| `typeName` | string \| null | 型号 |
| `coalition` | string \| null | 可查询或可靠继承的阵营 |
| `launch` | Launch | 冻结的发射数据 |
| `motion` | Motion | 当前运动信息 |
| `targetObservation` | TargetObservation | 当前/最近目标观察 |
| `lastKnownTarget` | TargetObservation \| null | 最近一次 object 观察的历史副本；此处非 null 时其 status 必须为 object |

### 8.2 Launch 与 Launcher

Launch 的必需字段：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `simTime` | number | 发射仿真时间 |
| `timeSource` | string | dcs_event 或 capture_time |
| `launcher` | Launcher | 发射者快照 |
| `initialTarget` | TargetObservation | 首次目标查询结果，可能不可用 |
| `initialPosition` | Vector3 \| null | 发射时取得的位置 |
| `initialVelocity` | Vector3 \| null | 发射时取得的速度 |
| `issues` | string[] | 发射数据缺失或降级说明 |

Launcher 的必需字段：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `status` | string | known、unknown、conflict |
| `source` | string | event_initiator、weapon_getLauncher、both、unavailable |
| `object` | ObjectRef \| null | 发射平台及发射时玩家快照 |
| `alternateObject` | ObjectRef \| null | 两来源冲突时的另一候选，正常为 null |
| `issues` | string[] | 缺失字段、冲突等 |

known 需要可靠的平台身份；玩家信息单独由 ObjectRef 的 occupancy 状态表达。两个来源身份不一致时为 conflict，object 保留事件发起者，alternateObject 保留 API 查询候选，下游不能视为已确认归属。发射者离开、飞机死亡或玩家换人均不修改 Launch。

建立 Launch 时优先即时查询玩家信息。只有周期缓存可用时，occupancyStatus 必须为 stale，occupancySampledSimTime 保留旧时间，不能改成发射时间冒充即时读取。Launch 中的玩家归属质量与平台身份质量分别判断。

### 8.3 TargetObservation

所有字段均必需：

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `status` | string | object、none_reported、unavailable、stale |
| `source` | string | weapon_getTarget 或 unavailable |
| `sampledSimTime` | number \| null | 最近成功查询时间；成功无返回也有时间 |
| `lastAttemptSimTime` | number | 最近尝试时间 |
| `lastSuccessfulStatus` | string \| null | object 或 none_reported；没有成功查询则 null |
| `object` | ObjectRef \| null | 本次/最近成功对象快照 |
| `issues` | string[] | 查询失败等问题 |

状态不变量：

- object：object 非 null，lastSuccessfulStatus=object。
- none_reported：object=null，lastSuccessfulStatus=none_reported。
- unavailable：object=null、sampledSimTime=null、lastSuccessfulStatus=null。
- stale：sampledSimTime 非 null，保留最近成功结果；由 lastSuccessfulStatus 判断保留的是对象还是无返回。

对象查询成功但身份部分缺失时，仍保存 object 并列出 issues，不能用附近飞机代替。lastKnownTarget 是历史目标，不得在当前查询无返回时当作当前目标显示。

### 8.4 导弹示例

以下为完整 Missile 记录示例；发射者和目标完整嵌入，即使引用对象不在当前完整遥测集合中，也可显示其身份。

```json
{
  "entityId": "missile-88",
  "kind": "missile",
  "dcsObjectId": "33554440",
  "typeName": "AIM_120C",
  "coalition": "blue",
  "launch": {
    "simTime": 125.45,
    "timeSource": "dcs_event",
    "launcher": {
      "status": "known",
      "source": "event_initiator",
      "object": {
        "entityId": "aircraft-17",
        "dcsObjectId": "16777729",
        "kind": "aircraft",
        "name": "Blue-1",
        "typeName": "F-16C_50",
        "coalition": "blue",
        "isPlayer": true,
        "playerName": "Pilot-A",
        "occupancyStatus": "ok",
        "occupancySampledSimTime": 125.45,
        "capturedSimTime": 125.45,
        "issues": []
      },
      "alternateObject": null,
      "issues": []
    },
    "initialTarget": {
      "status": "none_reported",
      "source": "weapon_getTarget",
      "sampledSimTime": 125.45,
      "lastAttemptSimTime": 125.45,
      "lastSuccessfulStatus": "none_reported",
      "object": null,
      "issues": []
    },
    "initialPosition": {"x": 10000, "y": 5000, "z": 20000},
    "initialVelocity": {"x": 600, "y": 0, "z": 0},
    "issues": []
  },
  "motion": {
    "status": "partial",
    "sampledSimTime": 125.5,
    "lastAttemptSimTime": 125.5,
    "issues": ["basis_unavailable", "in_air_unavailable"],
    "sampleSeq": 2510,
    "position": {"x": 10030, "y": 5000, "z": 20000},
    "velocity": {"x": 650, "y": 0, "z": 0},
    "speedMps": 650,
    "groundSpeedMps": 650,
    "basis": null,
    "inAir": null
  },
  "targetObservation": {
    "status": "object",
    "source": "weapon_getTarget",
    "sampledSimTime": 125.5,
    "lastAttemptSimTime": 125.5,
    "lastSuccessfulStatus": "object",
    "object": {
      "entityId": "aircraft-23",
      "dcsObjectId": "16777731",
      "kind": "aircraft",
      "name": "Red-1",
      "typeName": "FA-18C_hornet",
      "coalition": "red",
      "isPlayer": true,
      "playerName": "Pilot-B",
      "occupancyStatus": "ok",
      "occupancySampledSimTime": 125.5,
      "capturedSimTime": 125.5,
      "issues": []
    },
    "issues": []
  },
  "lastKnownTarget": {
    "status": "object",
    "source": "weapon_getTarget",
    "sampledSimTime": 125.5,
    "lastAttemptSimTime": 125.5,
    "lastSuccessfulStatus": "object",
    "object": {
      "entityId": "aircraft-23",
      "dcsObjectId": "16777731",
      "kind": "aircraft",
      "name": "Red-1",
      "typeName": "FA-18C_hornet",
      "coalition": "red",
      "isPlayer": true,
      "playerName": "Pilot-B",
      "occupancyStatus": "ok",
      "occupancySampledSimTime": 125.5,
      "capturedSimTime": 125.5,
      "issues": []
    },
    "issues": []
  }
}
```

## 9. 完整状态页 StatePage

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `snapshotId` | string | 冻结快照 ID |
| `pageIndex` | integer | 当前页，下标 0 开始 |
| `pageCount` | integer | 总页数，至少 1 |
| `nextCursor` | string \| null | 下一页不透明游标，最后页为 null |
| `assembledSimTime` | number | 快照构建时间，不能替代各字段采样时间 |
| `eventSeqAtCapture` | integer | 冻结时已处理进注册表的日志末端 |
| `scopeRevision` | integer | 冻结时的范围版本 |
| `coverage.aircraftInventory` | string | complete 或 partial |
| `coverage.missileInventory` | string | tracked_since_capture_start 或 partial |
| `coverage.captureStartedSimTime` | number | 本 epoch 捕获起点 |
| `coverage.issues` | string[] | 范围校验、跟踪丢失等 |
| `entities` | (Aircraft \| Missile)[] | 本页活跃实体完整记录 |

此处 complete 表示配置范围内的活跃集合清单覆盖，不代表每条实体的燃油等字段都成功。tracked_since_capture_start 明确排除无法补全的安装前导弹。

分片规则：

1. cursor=null 新建快照并返回第 0 页；新建会放弃此前未完成的快照。
2. 固定同一快照所有实体和页边界，确保内容、页码、pageCount 不受之后采样变化影响。
3. 每个 collector 仅保留一个冻结快照；最后一页读取后可以保留到下一次新建/范围变化，保证页重试可读，不立即销毁最后页。
4. 游标包含实现管理的源身份、快照、页及预算约束，消费者不解析。后续页保持兼容的响应预算；不足时明确报错，不能改变已冻结页边界。
5. 范围变化或快照替换使旧游标失效，返回 STALE_CURSOR。
6. Hook 先收齐并验证所有页，再原子替换完整集合；部分页不能引发“未出现即移除”。
7. coverage=partial 的类别不做基于缺席的批量移除，等待明确移除事件或后续覆盖完整快照。
8. 同一 snapshot 中实体 ID 不重复。引用专用实体可以不在 entities 中。
9. eventSeqAtCapture 不产生 ACK。下游仍处理全部历史日志，但只对快照水位之后的状态事件推进当前状态，避免旧出生事件复活实体。

## 10. 事件 Event 与详情

### 10.1 事件通用字段

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `eventSeq` | integer | 连续日志序号，1 开始 |
| `type` | string | 下面定义的事件类型 |
| `origin` | string | dcs_event 或 collector_observation |
| `dcsEventId` | integer \| null | 运行时原始事件编号；观察事件为 null |
| `simTime` | number | 原始事件时间或观察时间 |
| `capturedSimTime` | number | 处理时间 |
| `timeSource` | string | dcs_event 或 capture_time |
| `actor` | ObjectRef \| null | 发起者/主体的当时快照 |
| `target` | ObjectRef \| null | 该事件明确报告的目标，不靠历史目标猜测 |
| `weapon` | ObjectRef \| null | 事件武器，存在时含独立导弹 ID |
| `details` | object | 依 type 定义 |
| `issues` | string[] | 字段提取失败或数据不完整 |

原始事件编号按实际 DCS 常量填入，不把示例数字当固定映射。日志按捕获顺序编号，不能仅按相同 simTime 去重。kill/dead/hit 各自是真实记录，不因属于同一次战斗而在采集层合并。

### 10.2 details 定义

| type | details 必需字段 | 说明 |
| --- | --- | --- |
| `entity_born` | `entityId: string|null`, `entityKind: string|null` | 真正出生事件，初始扫描不伪造 |
| `weapon_fired` | `missileEntityId: string|null`, `launch: Launch`, `trackingStatus: string` | trackingStatus 为 tracking、unsupported、object_unavailable；没有对象时仍保留发射事实 |
| `hit`、`kill` | `{}` | 发起者、目标、武器保存在通用字段；提取不到则 null |
| `crash`、`dead`、`unit_lost`、`ejection`、`pilot_dead` | `{}` | actor 表示主体，不能互相替代 |
| `takeoff`、`land` | `place: ObjectRef|null` | 不同事件触发条件按目标版本验证 |
| `player_entered`、`player_left` | `reportedPlayerName: string|null`, `occupancyAfter: Occupancy` | 事件本身可能没有完整玩家名，明确空值 |
| `entity_removed` | `entityId: string`, `reason: string`, `lastMotion: Motion|null` | 保留最后有效位置与时间 |
| `weapon_track_ended` | `missileEntityId: string`, `reason: string`, `launch: Launch`, `lastMotion: Motion|null`, `lastTargetObservation: TargetObservation`, `lastKnownTarget: TargetObservation|null` | 短寿命导弹无需当前状态也能解释 |
| `target_observation_changed` | `missileEntityId: string`, `previous: TargetObservation`, `current: TargetObservation` | 仅两次成功结果变化；不是导引头失锁判定 |
| `capture_record_rejected` | `originalType: string`, `originalBytes: integer`, `reason: record_too_large` | 0.1.5 起，超过 32 KiB 的事件正文替换为同序号的明确丢失事实，issues 含 event_payload_lost；不能作为原业务事件使用 |

`reason` 枚举为 object_gone、tracking_lost、resource_limit、collector_stopped、unknown。object_gone 只描述存在性，不等于 impact。移除对象时尽量记录明确事实，不能仅因达到跟踪超时就写成命中。

## 11. EventBatch、缺失与 ACK

### 11.1 EventBatch

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `afterSeq` | integer | 本次采用的读取起点，不包含该序号 |
| `throughSeq` | integer | 本批覆盖的连续日志终点，含明确返回的缺失区间 |
| `latestEventSeq` | integer | 当前日志末端，只用于判断积压 |
| `hasMore` | boolean | throughSeq < latestEventSeq 时为 true |
| `gaps` | Gap[] | 本批覆盖的已知缺失区间 |
| `events` | Event[] | 按 eventSeq 升序排列的事件 |

`afterSeq+1` 到 `throughSeq` 的每个序号必须由 events 或 gaps 唯一覆盖，不能隐藏空洞；两者不能重叠。没有任何新项时 throughSeq=afterSeq。maxCount 限制日志项数量，字节预算可以使实际项数更少。

`afterSeq` 必须在实际 ACK 与 latestEventSeq 之间；小于 ACK 返回 CURSOR_BEFORE_ACK，大于末端返回 INVALID_EVENT_CURSOR。已拉取但未确认的数据允许重读。日志被溢出淘汰且尚未确认时，通过 gap 表达，不能当作已确认删除。

Gap 所有字段必需：`fromSeq`（integer）、`toSeq`（integer，包含边界）、`reason`（buffer_overflow）。Gap 不分配自己的新 eventSeq。捕获失败但未分配序号的情况只由 health/coverage 表达，不能伪造精确 gap。

### 11.2 ACK 契约

- ACK 表示 C++ 已按协商模式连续记录此前事件或明确缺失事实，不是 Hook 已读位置。0.2.0 网络适配显式协商 `ackMode=memory`：允许释放日志，但不保证服务进程退出后的历史恢复；durable 模式未实现。模式和 serverEpoch 在 [网络层](hook-server-v1.md) 校验，任务协议不增加网络字段。
- ACK <= 当前 ackEventSeq 时幂等返回实际位置。
- ACK > 已经交付过的最高 throughSeq 返回 INVALID_ACK。
- Hook 只能在自己已持有、且已由 C++ 连续确认的范围内推进，不通过跳读伪造连续消费。
- C++ 在绑定 instanceId 后按 `(missionSessionId, collectorEpoch, eventSeq)` 去重；gap 按源身份和区间纳入同一接收仓库。
- 任务环境在合法 ACK 后删除相应事件，并裁剪/删除相应 gap。
- 一个主服务确认链服务多个 UI；任何 UI 的播放/显示游标不得成为采集 ACK。

缺失批次示例。假定 1201～1250 已因溢出丢失，1251 是可读取的真实死亡事件：

```json
{
  "afterSeq": 1200,
  "throughSeq": 1251,
  "latestEventSeq": 1300,
  "hasMore": true,
  "gaps": [
    {"fromSeq": 1201, "toSeq": 1250, "reason": "buffer_overflow"}
  ],
  "events": [
    {
      "eventSeq": 1251,
      "type": "pilot_dead",
      "origin": "dcs_event",
      "dcsEventId": null,
      "simTime": 130.2,
      "capturedSimTime": 130.2,
      "timeSource": "dcs_event",
      "actor": {
        "entityId": "aircraft-17",
        "dcsObjectId": "16777729",
        "kind": "aircraft",
        "name": "Blue-1",
        "typeName": "F-16C_50",
        "coalition": "blue",
        "isPlayer": true,
        "playerName": "Pilot-A",
        "occupancyStatus": "ok",
        "occupancySampledSimTime": 130.2,
        "capturedSimTime": 130.2,
        "issues": []
      },
      "target": null,
      "weapon": null,
      "details": {},
      "issues": ["raw_event_id_unavailable"]
    }
  ]
}
```

此例 dcsEventId=null 是明确退化示例；正常 DCS 事件应保留实际原始编号。C++ 记录 gap 及 1251 后才能确认 1251，不能直接确认 1300。

## 12. Health 与能力变化

每次 exchange 返回 Health；计数在当前 epoch 内累计，不因 ACK 清零。

| 字段 | 类型 | 定义 |
| --- | --- | --- |
| `eventBufferCount` | integer | 当前保留事件条数，不含 gap |
| `eventBufferBytesEstimate` | integer | 当前日志的受控内存估算 |
| `gapRangeCount` | integer | 当前保留的缺失区间数 |
| `captureErrorCount` | integer | 回调/事件规范化失败次数 |
| `samplingErrorCount` | integer | 采样字段/对象读取失败累计 |
| `samplingOverrunCount` | integer | 采样落后或软预算超限次数 |
| `droppedEventCount` | integer | 日志溢出淘汰的事件条数 |
| `incompleteLauncherCount` | integer | 发射者未知或冲突的导弹发射数 |
| `aircraftCount` | integer | 当前完整遥测集合飞机数 |
| `missileCount` | integer | 当前活跃跟踪导弹数 |
| `issues` | string[] | 当前问题码 |
| `capabilities` | object | 与 initialize 同结构的当前能力 |

建议问题码：motion_read_failed、fuel_read_failed、mass_conversion_unverified、armament_read_failed、ammo_type_unknown、occupancy_read_failed、launcher_unknown、launcher_source_conflict、target_query_failed、event_buffer_overflow、inventory_partial、capture_continuity_unknown。

问题码可新增；下游未知问题码按“存在诊断信息”处理，不能因此把记录变成全字段有效。

## 13. 正常 exchange 响应示例

下面是另一个独立时刻的完整响应：采集范围已知没有活跃实体，也没有新事件。飞机与导弹实际记录分别采用第 7、8 节结构，不使用占位字符串或不完整实体冒充完整响应。

```json
{
  "protocolVersion": 1,
  "requestId": "req-exchange-empty",
  "op": "exchange",
  "ok": true,
  "missionSessionId": "mission-20261016-a",
  "collectorEpoch": "collector-1",
  "data": {
    "collectorSimTime": 200,
    "status": "ready",
    "configRevision": 1,
    "scopeRevision": 1,
    "ackEventSeq": 1300,
    "state": {
      "snapshotId": "snapshot-700",
      "pageIndex": 0,
      "pageCount": 1,
      "nextCursor": null,
      "assembledSimTime": 200,
      "eventSeqAtCapture": 1300,
      "scopeRevision": 1,
      "coverage": {
        "aircraftInventory": "complete",
        "missileInventory": "tracked_since_capture_start",
        "captureStartedSimTime": 0.18,
        "issues": []
      },
      "entities": []
    },
    "eventLog": {
      "afterSeq": 1300,
      "throughSeq": 1300,
      "latestEventSeq": 1300,
      "hasMore": false,
      "gaps": [],
      "events": []
    },
    "health": {
      "eventBufferCount": 0,
      "eventBufferBytesEstimate": 0,
      "gapRangeCount": 0,
      "captureErrorCount": 0,
      "samplingErrorCount": 0,
      "samplingOverrunCount": 0,
      "droppedEventCount": 0,
      "incompleteLauncherCount": 0,
      "aircraftCount": 0,
      "missileCount": 0,
      "issues": [],
      "capabilities": {
        "aircraftMotion": true,
        "aircraftFuel": true,
        "aircraftArmament": true,
        "playerOccupancy": true,
        "missileTracking": true,
        "weaponLauncherQuery": true,
        "weaponTargetQuery": true
      }
    }
  }
}
```

## 14. 响应预算与记录上限

上限包含整个信封、JSON 转义、状态、事件和健康度。不得按未转义字符串长度估算后直接截断输出。

- 事件通过 maxCount 和实际字节预算分页；状态通过冻结快照分片。
- 首次创建状态页时需要为请求中的事件批次及信封保留预算。后续页边界固定，Hook 可以独立调用事件读取追赶积压。
- 若组合读取预算放不下一个合法状态记录和一个待发送事件，返回 RESPONSE_BUDGET_TOO_SMALL，Hook 分开读状态/事件或增大预算；不能静默省略其中一类。
- 单条必需记录超过实例 maxRecordBytes 时返回 RECORD_TOO_LARGE，保留原数据并报告退化；不能通过裁掉发射者、类型或计数满足大小限制。
- 可限制/裁剪非必需的诊断长文本，但必须标记，不能改变源身份或核心语义。
- 大快照冻结过程的时间预算和内存峰值都需压测；本协议不把“总字节可分页”等同于“构建快照必然便宜”。

## 15. configure

请求包含 `baseRevision: integer` 和完整新 `config`（结构同 initialize）。新 revision 通常为当前 revision+1。

- 先校验并准备新配置，整体生效，不允许半数采样器使用新配置、半数使用旧配置。
- 当前 revision 和内容已经等于请求目标时幂等成功，即使重试中的 baseRevision 已落后。
- 其他情况下 baseRevision 不匹配返回 CONFIG_CONFLICT。
- 不重置事件序号、不清空未确认日志、不修改历史事件。
- 范围改变使 scopeRevision 递增并使现有快照游标失效。离开采样范围不等于实体死亡。
- 缩小事件缓存可能触发显式溢出缺口，不能静默删除。

成功 data 包含 `configRevision`、`scopeRevision`、`acceptedConfig`、`scopeChanged`（boolean）。返回实际配置。不能用配置关闭最低数据块而继续宣称满足最低数据契约。

## 16. shutdown

请求除信封外没有必需参数。成功 data：`status=stopped`、`stoppedSimTime:number`、`ackEventSeq:integer`、`latestEventSeq:integer`、`hasUnacknowledgedLog:boolean`。0.1.3 增加 `stopReason:string`，值为 mission_end_event 或 hook_shutdown；重复 shutdown 不覆盖首次停止原因。

操作停止采样、使调度器不再续约并注销事件处理器；重复调用幂等。仍保留普通数据、事件和缺失区间供 exchange 排空，不能隐含执行“丢弃所有日志”。停止阶段如需生成跟踪结束事件，先生成，再返回最终日志末端。

任务环境收到可用的 S_EVENT_MISSION_END 时主动执行同一停止流程；该控制事件不额外生成普通 Event，停止事实通过 status、stopReason、finalEventSeq 表达。此后 exchange 的 finalEventSeq 固定等于 shutdown 返回的 latestEventSeq。Hook 保持 afterSeq 逐页前进，连续取得事件或明确 gap 到该序号后才报告 tailComplete；该报告与 ACK 独立。

任务即将销毁时的最后读取是尽力而为。若环境先销毁，Hook 在上游会话结束信息中报告尾部未知；本协议不保证结束回调里必然还能进行任务调用。

## 17. 错误码

| code | 含义 | 恢复方式 |
| --- | --- | --- |
| INVALID_REQUEST | 类型、字段或枚举不合法 | 修改请求 |
| NOT_READY | 初始化/扫描尚未完成 | 限频重试 |
| PROTOCOL_MISMATCH | 不支持的主版本 | 使用匹配版本，不能覆盖未确认实例 |
| SESSION_MISMATCH | 任务会话不符 | 重新探测并核对来源 |
| EPOCH_MISMATCH | 采集器已更换 | 新段处理，禁止沿用旧 ACK |
| CONFIG_CONFLICT | 配置版本或内容冲突 | 读取当前配置后处理 |
| COLLECTOR_STOPPED | 停止实例收到运行初始化等请求 | 排空旧日志，不隐式复位 |
| INVALID_ACK | 确认越过已交付范围 | 使用 C++ 在协商模式下的连续确认位置 |
| CURSOR_BEFORE_ACK | 请求重读已确认并可被删除的数据 | 核对主服务 epoch 与接收游标，必要时报告不可恢复缺口 |
| INVALID_EVENT_CURSOR | 读取位置在日志末端之后或格式错误 | 核对源身份及位置 |
| STALE_CURSOR | 冻结快照已替换或范围改变 | 丢弃未完成快照，cursor=null 重读 |
| RESPONSE_BUDGET_TOO_SMALL | 合法响应无法放入本次预算 | 独立读取状态/事件或增加预算 |
| RECORD_TOO_LARGE | 单条必需记录超过硬上限 | 报告退化并调整部署限制，不能无限重试掩盖 |
| INTERNAL_ERROR | 未预期采集器异常 | 记录 context，限频探测与恢复 |

错误示例：

```json
{
  "protocolVersion": 1,
  "requestId": "req-old-epoch",
  "op": "exchange",
  "ok": false,
  "missionSessionId": "mission-20261016-a",
  "collectorEpoch": "collector-2",
  "error": {
    "code": "EPOCH_MISMATCH",
    "message": "Request targets an earlier collector epoch",
    "retryable": false,
    "context": {"ackEventSeq": 0}
  }
}
```

## 18. 尚待部署验证的接口假设

协议在以下事项确认后才能标为已实现/已验证：

1. 比赛使用的 DCS 版本和真实任务脚本执行路线。
2. 机型 getFuel 的读数及外挂油箱口径；任何质量换算的验证记录。
3. getAmmo 对空弹药、弹药描述类型键及补给/换装的行为。
4. 玩家名称查询与多座席、接管状态的语义。
5. 每类导弹的事件发起者、getLauncher 和 getTarget 的可用性。
6. 各事件的触发与任务结束阶段环境存活情况。
7. 预计规模下的采样、冻结、编码耗时及内存预算。

参考来源及完整验收矩阵见 [架构文档](../architecture/mission-hook.md#13-实施前验收清单)。


## 0.1.4 实现说明：频率及编码复用

协议仍为 v1。周期采样默认 1 Hz 仿真时间，Hook 正常 exchange 默认 1 Hz 真实时间。onEvent 即时捕获，不合并或覆盖不同 eventSeq。事件在捕获时冻结并编码；传输时拼入响应的仍是 JSON 对象数组，不是需要二次解码的字符串数组。序号、顺序、重读与 ACK 语义保持不变。

同一实体的运动、燃油、武器、玩家占用等属性放在同一 entities 元素中，保留各块采样时间。整条实体记录不跨页拆分；state 与 eventLog 在预算允许时同一 exchange 返回。事件中的历史对象引用不被当前状态覆盖。任务结束补拉继续分页执行。
