# C++ 主服务器 0.4.0 与 Hook 网络传输 0.3.0

本版本已完成 1 Hz 对象状态、事件去重、memory ACK、重连、恢复基线、结束补拉，以及账号授权、WS/WSS 订阅、导播本地服务与网页。导播与 OBS 操作见 [导播使用说明](director.md)，新增接口见 [浏览器协议](../protocol/browser-v1.md)。下文保留各版本的历史验证记录。

## 构建

需要 Python 3.11+（下载/打包/测试用）、CMake 3.24+、OpenSSL 3.x 开发库及支持 C++20 的 Windows x64 编译器。运行成品服务器与 Hook 不需要 Python，导播本地服务需要 Node.js 24+。

```powershell
python tools/fetch_boost.py
cmake -S . -B build -A x64
cmake --build build --config Release
cmake --install build --config Release --prefix dist/server
python tools/package.py
```

Boost 固定为 1.90.0，下载脚本校验官方归档 SHA-256。只使用头文件与 Boost.JSON 源码，许可证随服务器安装。本机 MSVC 安装的链接器报告 MSPDB140.DLL 版本不匹配，因此已验证的构建使用 `C:\msys64\ucrt64\bin` 的 GCC 15.2 / Ninja：

```powershell
$env:PATH = 'C:\msys64\ucrt64\bin;' + $env:PATH
cmake -S . -B build-gcc -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-gcc -j 4
cmake --install build-gcc --prefix dist/server
```

MinGW 构建静态链接 GCC 运行库和 OpenSSL；必要时配置 `-DOPENSSL_ROOT_DIR=C:/msys64/ucrt64`。成品 `dist/server/dcs-esport-server.exe` 不要求 MSYS2 运行环境，仍依赖 Windows 系统 DLL。Boost/OpenSSL 许可证随安装分发。

## 配置、启动、安装

在项目根目录运行：

```powershell
python tools/package.py
./tools/Configure-Network.ps1
./tools/Server.ps1 Start
./tools/install.ps1 -SavedGamesPath 'E:\9950XSavedGames\DCS' -HookFile './runtime/deploy/DcsEsportHook.lua'
```

Configure-Network 首次生成随机 Hook/API 凭据到 `runtime/server/config.json`，后续保留原凭据，并将网络配置内嵌到 `runtime/deploy/DcsEsportHook.lua`。配置文件和部署包不进入版本控制，也不应对外分享。修改端口/instanceId 后重新运行该脚本，再重启服务并部署 Hook。普通 `tools/package.py` 生成的通用包默认关闭网络、没有凭据，不能直接替换已配置的部署文件。

install 会备份目标 Hook、复制并核对哈希。仍只部署一个 Lua 文件；任务环境不读取任何外部采集脚本，也不加载网络模块。Hook 在自身环境加载 DCS 原生 `socket.core`，网络不可用时记录错误，任务采集继续按有界缓存工作。

服务器默认 TCP 9081、HTTP 9080，均仅监听 127.0.0.1；脚本隐藏启动窗口并验证 healthz。DCS 已启动时，需要重启 DCS 才会加载新 Hook。服务不需要先于 DCS 启动，Hook 会退避重连。

```powershell
./tools/Server.ps1 Status
./tools/Server.ps1 Stop
```

Stop 仅停止 PID、进程路径和启动时间均与本项目记录匹配的进程。停止会丢弃服务内存历史；重新启动后 Hook 以 memory ACK 基线恢复，已释放历史标明缺口。

## 数据位置与查看

- 最新对象/事件保存在 C++ 进程内存，可由 [网络协议文档](../protocol/hook-server-v1.md) 中的 HTTP 接口读取。
- `runtime/server/stdout.log`：服务启动日志；`stderr.log`：被拒绝的协议请求；都不记录凭据或逐条比赛数据。
- `runtime/server/process.json`：本项目启动的进程身份。
- DCS `Logs/dcs.log`：Hook 加载、连接、serverEpoch 与网络错误。
- 文件诊断默认关闭；需要时将 Hook CONFIG 中 diagnosticsEnabled 改为 true。文件诊断不参与 ACK，也不是服务器输入。

查询完整状态示例（终端不会回显凭据）：

```powershell
$settings = Get-Content ./runtime/server/config.json -Raw | ConvertFrom-Json
$headers = @{Authorization = 'Bearer ' + $settings.apiToken}
$base = "http://127.0.0.1:$($settings.httpPort)"
$sources = Invoke-RestMethod "$base/api/v1/sources" -Headers $headers
$sources | ConvertTo-Json -Depth 20
# 用实际 sourceId 替换下例 1。
Invoke-RestMethod "$base/api/v1/sources/1/snapshot" -Headers $headers | ConvertTo-Json -Depth 30
```

## 验证与边界

```powershell
python tests/run.py
python tests/run.py --runtime luajit21
python -m unittest discover -s tests -p test_package.py
python tools/smoke.py
python tests/test_server.py
```

网络测试需要允许本机监听/连接。默认测试 `build-gcc/dcs-esport-server.exe`；可用 DCS_ESPORT_TEST_SERVER 环境变量指定其他构建。原生集成测试默认使用本机 DCS 安装中的 luae.exe，可用 DCS_ESPORT_TEST_LUA 覆盖；缺少它会显式跳过该项，不能视为原生验证通过。

覆盖内容：TCP 分片、半帧/ACK 丢失、重复正文和冲突、隐含缺号与显式 gap、错误凭据/旧连接/超长帧、快照缺页不发布、旧新任务隔离；原生 Lua 跑打包 Hook，通过真实 TCP 收发，验证 1 Hz、飞机必需字段、导弹发射者和目标、断线、服务重启、结束时断线及 350 条积压补拉。测试报告在 `runtime/network-native/summary.json`。

这些使用模拟 DCS 任务对象，不能代替真实飞行测试。实机验收应重启 DCS 后跑任务并查看 Status：snapshotCount 约每秒增加一次；receivedThrough 与 Hook confirmedSeq 最终一致；采集器仍可访问时 actualAck 也到达最终水位，否则 collectorAck.state=unverified 并显示原因；duplicateEvents 只统计合法重发，acceptedEvents 不重复；结束后 serverTailComplete=true。正常无溢出且服务没有重启时 historyComplete 应为 true。

2026-10-16 本机验证结果：Lua 行为回归 73 项通过（Lua 5.1、LuaJIT 2.1、DCS 原生 luae），单文件打包 3 项通过，真实 TCP/HTTP 集成 7 项通过。原生联调的 3.2 秒窗口收到 3 个快照；累计建立 4 次连接，第一任务最终水位 373，第二任务独立从 1 开始；第一任务结束时断线后仍补发至 373，Collector 确认后缓存字节归零。中途重启服务器，已确认的 1～21 被明确记作恢复缺口，未伪报完整历史。此项是原生 Lua + 模拟任务 + 真实网络验证，不是真实飞行记录。

如果 DCS 结束后不再提供任何帧回调，网络待发队列要等下一次回调继续，停止回调不阻塞等待。退出 DCS、服务进程崩溃、缓存溢出均不属于无损保证。当前没有持久模式；网络预算也不是硬实时承诺，需后续记录真实比赛规模下的帧耗时。

## 0.2.1 修复及实机验收（2026-10-16）

结束后的服务器 ACK 立即尝试回传采集器，后续失败以一秒间隔重试，连续三次失败停止并显示 unverified；明确的源变更/采集器不存在立即停止。不会虚增 actualAck。结束元数据随着确认更新，服务器分别提供 serverTailComplete 与 collectorCleanupComplete；最后一次 health 在结束后标记 healthFresh=false。常规采集仍为 1 Hz，单文件注入布局不变。

协议拒绝日志统一为 JSON 行，连同此前未记录的零长度/超长帧头一起记录来源地址、源端口、接收端口、认证状态、连接标识、阶段、原因和四字节帧头；不记录正文或凭据。隔离测试的六次拒绝覆盖 HTTP 错投、零长度、超长、损坏 JSON、认证失败和事件正文冲突，验证日志与计数一一对应。测试样本输出到 runtime/network-rejections.json，不污染运行中的主服务器计数。

实机使用 `E:\DCS_NewMission\16V16_Test.miz`，DCS 参数为 `--server --norender --webgui -w DCS`。2026-10-16 22:32:32（UTC+8）在仿真约 100 秒、9 发导弹仍在跟踪时调用正常 stopMission：

| 检查 | 实测结果 |
| --- | --- |
| 事件连续性 | 1～32 全部收到，32 条唯一事件，duplicateEvents=0，gaps=[] |
| 导弹生命周期 | 9 次发射、9 条 collector_stopped 跟踪结束，另有 14 条目标观察变化 |
| 任务结束补拉 | 23 → 32，tailComplete/serverTailComplete/historyComplete 均为 true |
| 最终 ACK | 22:32:32.560 尾部收齐；22:32:32.563 actualAck=confirmedSeq=32，首次结束确认调用成功 |
| 采集器清理 | collectorAck.state=confirmed，collectorCleanupComplete=true，事件缓存条数/字节均为 0 |
| 频率 | 收到 108 个快照；采集到的正仿真时间间隔中位数 1.007 秒。观察程序有漏采，最大观察间隔不等于服务采样间隔 |
| 错误 | protocolErrors=0；采集/采样/溢出计数均为 0 |

停止后继续观察 15 秒，确认结束状态稳定。仅退出本次测试启动的 DCS 进程，逐字节恢复原 serverSettings.lua，核对任务文件哈希未变。C++ 接收服务器保留运行。完整证据在 runtime/verification/ack-fix-20261016-222928，包括 report.json、连续查询记录、快照、完整事件、DCS 日志和恢复核验。

回归覆盖 78 项 Lua 行为测试、3 项单文件打包测试、8 项 TCP/HTTP 集成测试及单文件冒烟。原生 Lua 网络测试另外覆盖结束时断线后补发至 373、ACK 后采集器缓存归零。模拟的环境不可用路径验证重试上限、明确失败状态和新旧任务隔离；此次真实任务验证了最终 ACK 成功回传路径。

## 0.3.0 链路风险修复

- 尾部未读齐而环境消失时，有限失败后停止 draining，明确 captureClosed 和错误；不伪造最终序号。
- 冻结快照续页按帧有界推进，新快照和任务采样保持 1 Hz；尾批先于普通状态发送，同时控制消息有公平机会。
- 超大事件变为同序号 capture_record_rejected，正常事件继续；超大实体从当前快照排除，并在 coverage.excludedEntityCount/excludedEntities 中列出，coverage 标记 partial。最多列出 16 个身份，总计数不截断。排除不能当成飞机被击落。
- 服务器按连接和接收时间计算 online/statusFresh/snapshotFresh；采集完整性、传输完整性、历史保留分开显示。
- 超过 64 个完整源时，已结束且确认完成的旧源变为紧凑记录；最多 128 个紧凑确认记录。未结束、未确认的会话受到保护。
- HOOK 输出 exchange CPU 时间指标；网络和文件诊断未监听的事件/状态不再做无效深拷贝。

2026-10-16 的 0.3.0 首次实机测试在约 101 秒、6 发活动导弹时停止。21 条事件连续收齐，无重复、无 gap、协议拒绝 0；101 个快照的正仿真时间间隔中位数 1.006 秒。此次任务环境在最终 ACK 到达前关闭，actualAck=15、confirmedSeq=21；三次失败后正确显示 unverified 并停止重试，未宣称缓存清理成功。证据在 runtime/verification/risk-v030-20261016-231335。该实测发生在最后一次发送公平性与空监听复制优化之前；最终部署仍须按构建哈希核对对应验证。

UI 与控制服务的完整范围、每画面开关和完成门槛见 [UI 实施规格](../architecture/ui-control.md)。
