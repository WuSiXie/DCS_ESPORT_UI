# 主服务器、导播服务与浏览器协议 v1

实现版本：C++ 0.4.1 / 导播服务 0.8.0。任务采集器与 HOOK 协议不变，采样仍为 1 Hz。

## 主服务器登录与源权限

账号配置由管理员在服务器机器上使用 `tools/accounts.py` 管理。文件格式为 `{version:1,users:[...]}`，每个用户包含 username、role、enabled、instances 和 password。role 为 admin/director/viewer；instances 为允许读取的 instanceId 列表，`["*"]` 表示全部实例。当前 HOOK 接入仍仅允许配置的单个实例。

password 为 `{algorithm:"pbkdf2-sha256",iterations:600000,salt:"小写十六进制",hash:"64位小写十六进制"}`。随机盐至少 16 字节，派生值 32 字节。验证在两个工作线程执行，不阻塞接收事件循环。不存在的用户名也执行相同派生过程；登录按来源 IP 与用户名分别限制每分钟 5 次，最多 8 个待验证请求。

| HTTP | 请求 / 返回 |
| --- | --- |
| `POST /api/v1/auth/login` | `{username,password}` → `{accessToken,expiresIn:28800,user,serverEpoch}` |
| `GET /api/v1/auth/me` | Bearer 会话 → `{username,role,instances}` |
| `POST /api/v1/auth/logout` | Bearer 会话 → `{loggedOut:true}`，撤销关联 WS |
| `POST /api/v1/auth/ws-ticket` | Bearer 会话 → `{ticket,expiresIn:30}` |
| `GET /api/v1/sources` | 仅返回允许读取的源，增加 createdOrder 用于选择最新任务 |
| `GET /api/v1/sources/{id}/snapshot` | 受源权限限制，未知与未授权均返回 404 |
| `GET /api/v1/sources/{id}/events?afterSeq=N` | 受源权限限制，窗口外或超前游标返回 409 |
| `GET /api/v1/status` | admin 或回环诊断凭据；含 webSubscribers |

会话随机值为 32 字节，8 小时过期；仅内存保存，主服务重启后需重新登录。账号文件每秒至多检查一次，密码/角色/范围/启用状态变化会撤销该账号已有会话。配置损坏或无法读取时拒绝已有会话，不沿用旧授权。配置恢复后可以重新登录。会话最多 1024 个，一次性票据最多 1024 个。

既有静态 API token 只用于回环运维诊断，不能换取浏览器票据。HOOK token 独立。普通浏览器若提供 Origin，必须与目标 HTTP(S) Origin 相同；未开放 CORS。

## WebSocket

使用 `ws(s)://主服务/ws/v1/telemetry?ticket=...`。票据 30 秒有效、成功升级后立即消耗；长期访问 token 不放 URL。导播本地服务发起连接，浏览器不会得到上游 token 或票据。

所有服务端消息包含 `type` 和 `serverEpoch`。每个连接最多订阅 16 个源，最多 32 个订阅连接；单条客户端消息 32 KiB。每连接待发队列最多 16 MiB，超过即断开该慢端，缓冲仍保留至异步写结束，避免悬空引用。接收端与 Web 端连接额度分开，HTTP 慢端不能占完 HOOK 接入额度。

| 方向 / type | 字段与含义 |
| --- | --- |
| S → C `welcome` | protocolVersion=1、user；连接建立 |
| C → S `subscribe` | sourceId，恢复时带 afterSeq 与 serverEpoch |
| C → S `unsubscribe` | sourceId |
| C → S `ping` / S → C `pong` | 应用层存活检查 |
| S → C `sources` | sources 数组，每秒发送一次，均已按权限过滤 |
| S → C `subscribed` | sourceId、afterSeq、historical |
| S → C `snapshot` | sourceId、source 身份、state 完整快照或 null；只发布完整分页组装结果 |
| S → C `events` | sourceId、events、throughSeq、receivedThrough、gaps、historical |
| S → C `resync_required` | sourceId、reason，可能有 historyStart |
| S → C `source_removed` | sourceId，源不可读或已释放 |
| S → C `error` | error，可能有 sourceId |

首次订阅建立快照基线，最多取最近 128 条历史事件，historical=true，不重新触发播报。恢复时 afterSeq 仍在保留窗口且 serverEpoch 相同则补发后续事件；按源、epoch 和 eventSeq 去重。每批最多 128 条，约 512 KiB。

throughSeq 是本次完整覆盖的游标，包括显式 gap；receivedThrough 是服务器已收到的最大序号，不得直接跳过尚未分页送达的事件。epoch 变化、游标超前或历史淘汰触发 resync_required，再建立历史基线。基线期间新到达的事件单独作为 live 批发送。没有将浏览器确认与 HOOK ACK 耦合。

## 导播本地服务

仅绑定 127.0.0.1。每个服务有一个当前登录账号，可打开多个控制页和输出；另一个服务使用另一个端口、目录与独立会话。按「上游地址 + 用户名」散列分目录保存输出，切换账号不复用另一账号的配置/只读密钥。

本地登录设置 HttpOnly、SameSite=Strict Cookie，控制写操作还要求 X-CSRF-Token 与正确 Origin。Host 必须为本机服务的 localhost/127.0.0.1 和端口。viewer 的配置写操作返回 403。主服务会话只存在本地服务内存；启动后需要重新登录。

| HTTP | 用途 |
| --- | --- |
| `POST /api/login` | `{username,password}`；转交上游验证，成功返回 user、csrf |
| `GET /api/session` | 用户、csrf、连接状态、源列表、功能与默认配置 |
| `POST /api/logout` | 撤销上游会话、本地控制会话及输出访问 |
| `GET /api/outputs` | 当前账号全部输出，含只读 OBS URL |
| `POST /api/outputs` | `{config}`，创建输出，最多 12 个 |
| `PUT /api/outputs/{id}` | `{revision,config}`，版本不符返回 409 |
| `DELETE /api/outputs/{id}` | `{revision}` |
| `GET /api/control/stream` | 控制 Cookie 验证，SSE 推送控制状态 |
| `GET /api/output/{id}/state` | 单输出 Bearer 只读密钥，返回该画面与数据 |
| `GET /api/output/{id}/stream` | 同上，SSE 实时推送 |

OBS 地址是 `/output/{id}#readKey`。fragment 不发送给 HTTP 服务或 Referer；页面取出后仅用于输出读取接口的 Authorization。密钥不能调用配置写接口，也不包含上游会话。退出登录、账号撤销或切换账号后旧输出停止读取并清空显示。

SSE 事件名为 state，data 为 JSON。本地每 100 ms 合并变更；订阅最多 32 个，单次消息最多 16 MiB，积压超限断开。客户端重连后收到当前状态，已收过事件保留游标，不重播相同序号。每源本地事件展示缓存最多 200 条 / 约 2 MiB。

## 输出配置

每个输出包含 id(UUID)、revision、config；服务端另存 readKey，普通输出状态不返回该密钥。

控制台的十六项 `features` 开关实时提交并持久化：沿用 `PUT /api/outputs/{id}` 与 revision 检查，提交内容从当前已保存配置合并开关变更，避免把其他草稿同时发布。快速连点串行提交并合并尚未发送的最终意图；失败后恢复已保存开关并提示。其他输出字段仍由「保存」提交。

| config 字段 | 定义 |
| --- | --- |
| name / layout | 最长 60 字画面名；overview（比赛直播） / tactical（紧凑阵容） |
| sourceId / sourceEpoch / followLatest | 固定源同时绑定主服务 epoch，避免重启后的 sourceId 复用；或跟随 createdOrder 最大的授权源 |
| aircraftId / missileId | 焦点对象 ID，可为 null |
| features | match/map/roster/missiles/events/status/fuel/speed/altitude/loadout/teamLogos/mapMissileName/mapMissileLauncher/incoming/incomingName/incomingLauncher 十六个独立布尔值；旧配置缺少扩展项时补 true，显式非布尔值拒绝 |
| match | title、blueName、redName、blueScore、redScore、round；比分 0～999，人工维护 |
| filters | coalition(all/blue/red/neutral)、playersOnly、missileFocusOnly、search、sortBy(name/speed/fuel/altitude)、eventTypes |
| appearance | transparent（默认 true）、safeMargin(0～120 px，大于 32 时整体缩小 HUD)、labels、targetLines |
| units | aviation(kt/ft) / metric(km/h/m) |
| eventCount / eventDurationSec | 1～12 条，3～120 秒 |

输出状态含 output、connection、serverEpoch、source、sourcesReceivedAt、snapshot、events、gaps、resync、serverTime。sourcesReceivedAt 是本地服务最后收到源摘要的时间，用于在连接异常时继续计算数据年龄；仅本地网页读取，不依赖主机间时钟同步。source 的在线、新鲜度、采集完整性、传输完整性、历史保留分别展示。未知速度/燃油显示「—」，未知挂载不作为空挂载，身份未知不当 AI。燃油原始比例可超过 100%，数值不截断；条形只按视觉容量限制。目标分当前观察、未报告目标及最后观察，导弹跟踪结束不当命中。

## 标牌与队伍配置扩展（导播 0.5.0）

旧配置缺少 `competition`、`nameplates` 或 `docks` 时补默认值，不改变原有功能开关；`features.teamLogos` 默认 true。配置仍通过同一带 revision 的保存接口提交。为了内嵌两张队标，本地请求体上限改为 512 KiB，C++ 登录接口上限不变。

| 字段 | 定义 |
| --- | --- |
| competition.mode | `coalition` 或 `teams`；teams 只显示手动池成员，不使用 DCS 阵营作为队伍依据 |
| competition.blueLogo / redLogo | 空串或 PNG/JPEG/WebP base64 data URL，最长 100000 字符；不接受 SVG、外部 URL 或 HTML |
| match.blueName / redName、blueScore / redScore | 兼容原字段，队伍模式分别表示左队/右队名称与人工比分（0～999） |
| nameplates.fields | slot/name/unitName/type/occupancy/coalition/fuel/speed/altitude/loadout，各自布尔值 |
| nameplates.width / scale | 默认宽度 240～520，缩放百分比 50～150 |
| nameplates.blueCount / redCount | 两组自动排布同时显示数 0～16，独立 Dock 不占此配额 |
| nameplates.rotate / rotationSec | 轮换开关 / 周期 3～120 秒 |
| nameplates.filters | occupancy: all/player/ai/unknown，type/weapon 子串；fuelMin/Max、speedMin/Max、altitudeMin/Max 为数值或 null，单位分别为 % / km/h / m |
| nameplates.overrides[] | 最多 256 条；unitName 为单位名或 `player:玩家名`；visible、fields 稀疏覆盖、width/scale 可为 null、dock 可为 null |
| nameplates.fixedSlots[] | 最多 32 席；id UUID、label、binding: unit/player、unitName、playerName、team: blue/red、dock。玩家绑定必须有名字，飞机绑定必须有 Dock。每个绑定对象不得重复 |
| docks | match/map/blue/red/aircraft/missiles/events/status/blueLogo/redLogo，各项为 null（默认布局）或 Dock |
| Dock | `{anchor,x,y}`；anchor 九种 top-left/top-center/top-right/middle-left/center/middle-right/bottom-left/bottom-center/bottom-right，整数偏移 x ±1920、y ±1080 |
| outputState.aircraftLedger[] | 源内紧凑飞机身份/最后玩家/死亡事实缓存，最多 512 条，用于固定席位。不是新的事件流，不参与任务事件 ACK |

固定席位死亡依据为 crash/dead 的 actor、kill 的 target 或明确的玩家断线，不能把 kill 的发射者判死。player_left 仅代表离开飞机。玩家池新飞机匹配仍由 mission occupancy.playerName 提供，不把网络 slot 猜作任务 runtimeObjectId。同名或同时匹配多机显示 ambiguous。

预览 iframe 仅在 `?editor=1` 且消息来自同源 parent 时接受 `dcs-preview`（config/editing），返回 `dcs-dock-change`（nameplates/docks）；该通道只改草稿，正式写入仍经登录、CSRF、revision、严格字段校验。OBS 页无编辑手柄。


### 队伍颜色扩展（导播 0.5.1）

`competition.blueColor` / `redColor` 分别为队伍一/二颜色，严格使用六位十六进制 `#RRGGBB` 字符串，保存时转小写；缺失字段补 `#56bbfa` / `#ff6970`，显式 null 或不合法值拒绝。仅 `competition.mode=teams` 时用于渲染，阵营模式不覆盖原有红蓝色。队名仍使用 `match.blueName` / `redName`，选手池名称编辑入口与原赛事信息入口修改同一字段。


### 固定数量与元素布局扩展（导播 0.6.0）

`nameplates.fixedCount` 为布尔值，旧配置缺失时补 false。启用时 roster 自动补齐 blueCount/redCount，空位仅是视图占位，不产生任务实体或事件。

`elementLayouts` 为对象，旧配置缺失时补 `{}`，最多 1024 项。键为组件键（例如 `map`）、标牌/席位键（`plate:单位名` / `slot:UUID`），或追加内部元素后缀（例如 `match/blue-score`、`slot:UUID/fuel-bar`）。每项为 `{dx,dy,scaleX,scaleY}`，dx/dy 为局部整数像素偏移（分别 ±3840 / ±2160），scaleX/scaleY 为有限数值 0.1～8。只接受已知字段和合法键前缀，不能写入任意 CSS。

组件和标牌的外层位置仍由 docks / override.dock / slot.dock 保存；内部位移及各层缩放通过 elementLayouts 保存，所有设置仍受 revision、CSRF 和账号权限校验。预览 `dcs-preview` 增加 editingDetails；`dcs-dock-change` 增加 elementLayouts。Shift 为本次指针交互状态，不持久化为全局设置。


### 选手目录与导弹显示扩展（导播 0.7.0）

新增 `features.mapMissileName`、`mapMissileLauncher`、`incoming`、`incomingName`、`incomingLauncher`，均布尔值、默认 true，缺失时补默认值。通过现有 revision 接口实时保存，格式错误拒绝。小地图导弹文字不依赖 `appearance.labels`（该字段控制飞机标签），导弹图标及轨迹仍使用现有地图数据源。

选手小窗不新增网络接口。当前在线来自当前任务的 `source.hookStatus.players.records[].connected` 和状态新鲜度；历史使用同记录、`aircraftLedger[].lastPlayerName` 及控制台会话中观察到的名称。拖入后写入已有 `nameplates.fixedSlots` 的 `binding=player`、`playerName`、`team`，跨池拖动更新 team、不创建重复玩家。身份绑定与既有同名冲突规则保持一致。

来袭由完整 snapshot.entities 中 kind=missile、targetObservation.status=object 且 object.entityId 等于标牌飞机 entityId 的记录计算，按导弹 entityId 去重。名称为 identity.typeName 或 typeName；发射者来自 launch.launcher，只有 status=known 才作为确定身份显示，conflict/unknown 显示对应状态。不回退 lastKnownTarget。不使用 missileFocusOnly 等显示筛选来计算来袭。

来袭提示布局沿用 `elementLayouts["slot:<id>/incoming"]` 或 `elementLayouts["plate:<unitName>/incoming"]`。Hook 和 C++ 传输协议、1 Hz 周期不变。


### 自适应元素尺寸（导播 0.7.1）

elementLayouts 字段及数值范围不变，scaleX/scaleY 现在表示目标外框相对基础尺寸的比例。浏览器以实际宽高和等比布局缩放重排内容，文字不进行各向异性拉伸；dx/dy 仍是元素局部坐标偏移。地图像素缓冲由显示尺寸和 DPR 动态计算，不写入协议。取消预览只恢复本地草稿到最新已保存 config，不发 PUT，已提交 features 不回退。新队标保留最多 1024 像素边长，仍遵守原 data URL 字节上限。


### 移除状态栏控制与特写（导播 0.8.0 / C++ 0.4.1）

新配置仅接受 overview/tactical，不再接受 followCamera、features.aircraft、docks.aircraft 或 elementLayouts 中 aircraft 及 aircraft/*。旧磁盘配置由加载迁移器清理这些字段，并将 focus 转成 overview；原选手特写默认名称转为比赛直播，其他自定义名称和输出身份不变。迁移后持久化，接口不再输出废弃字段。

本地 /api/sources/{id}/camera-control 已移除（404），主服务相应 POST 不再支持（405），不维护 cameraControl 或发送 camera_control。新 HOOK 不报告 hookStatus.camera；旧 HOOK 上报的不透明 status 仍可接收，但不触发任何视角或状态栏命令。
