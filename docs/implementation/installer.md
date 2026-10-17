# Windows 离线安装与自动修复

安装包为 `dist/installer/DCS-Esport-UI-Setup-0.8.0.exe`，面向 Windows 10/11 x64。内置微软 .NET Framework 4.8 完整离线安装包、Node.js 24、C++ 服务、网页、单文件任务 HOOK 与 PDF 手册；目标电脑运行不需要 Python、npm 或编译器。安装器不启动 DCS，也不修改任务 .miz。

## .NET 环境自动准备

外层为静态链接的原生 Win32 程序，自身不依赖 .NET。先读取 HKLM 的 `SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\Release`，同时检查 32/64 位视图；Release >= 528040 表示已有 4.8 或更高版本（包括 4.8.1），直接进入项目安装，不降级、不重装。

缺少时，从 EXE 内释放微软完整离线包，验证固定 SHA-256 和离线 Authenticode 签名后，以管理员授权运行 `/passive /norestart`。外层和项目安装仍保留当前用户身份；仅微软安装程序提升权限。Windows UAC 授权由用户确认，无法自动跳过。

- 返回 0 且再次检测到 4.8 后进入项目安装。
- 返回 3010/1641 时提示需要重启，停止后续步骤；不强制重启，也不提前宣称项目已安装。用户自行重启后重新打开同一安装包继续。
- 取消授权（1223）、取消安装（1602）、系统不满足要求（5100）及其他失败均停止后续安装，并记录结果。返回 0 但注册表仍缺少所需版本也不会继续。
- 缓存与微软安装日志位于 `%LOCALAPPDATA%\DcsEsportUI\SetupCache\<安装器哈希前缀>`。损坏的缓存会从内嵌资源恢复。离线准备不使用 Web 安装器；Windows 自身必要的更新不在本项目包内。

微软离线包来自 [官方发布说明](https://support.microsoft.com/en-gb/servicing/dotnetframework/2019/10/microsoft-net-framework-4-8-offline-installer-for-windows)，固定 SHA-256 为 `0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40`。版本检测和退出码依据 [微软版本检测文档](https://learn.microsoft.com/en-us/dotnet/framework/install/how-to-determine-which-versions-are-installed)及[部署文档](https://learn.microsoft.com/en-us/dotnet/framework/deployment/deployment-guide-for-developers)。

## 安装

1. 双击安装包，先自动准备 .NET 环境，随后默认安装到当前用户的 `%LOCALAPPDATA%\Programs\DcsEsportUI`。项目本身无需管理员权限；缺少 .NET 时安装系统组件需要管理员授权。手动选择的目录须有写权限。不覆盖任意非空目录或开发项目。
2. 检查“保存的游戏根目录”。先读 `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`，再读 `Shell Folders` 中 `{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}`，展开 `%USERPROFILE%` 等变量。无注册表值时调用 Windows `SHGetKnownFolderPath(FOLDERID_SavedGames)`，最后回退用户目录并提示核对。
3. 勾选实际使用的 DCS 配置目录。支持 DCS、DCS.openbeta、自定义 `-w` 配置；可“选择 / 扫描”其他根目录，或“添加配置目录”。默认只勾选名为 DCS 的目录，避免误装到探针等配置。未选择时可先安装程序，之后补装 HOOK。
4. 填首次登录账号和两次密码（12-256 字符）。默认端口 HTTP 9080、HOOK 9081、导播 9170，可在首次安装时调整。已有安装保留原账号和端口。
5. 点击“安装 / 更新”，完成后点击“启动并打开”。浏览器中使用刚设置的账号登录。HOOK 安装或修复后重启 DCS 才生效。

更换或迁移 DCS 配置目录后，重新勾选新目录并点击“安装 / 更新”。取消勾选只停止维护旧目录，不会删除其中原有 HOOK；卸除旧目录中的采集时请手动移走 `DcsEsportHook.lua`。如果旧目录已不存在，先改选新目录再更新，可继续使用原账号和画面配置。

日常使用桌面或开始菜单的“DCS 电竞 UI”入口。“启动并打开”会先校验和自动修复，再启动本安装的服务并打开控制台。关闭管理窗口不会结束服务；“停止服务”才停止本安装的服务。其他项目实例或无关进程不会因端口冲突被终止。

## 自动修复的范围

- 内嵌安装内容使用 SHA-256 校验；对程序、网页、Node.js、文档和 HOOK 模板逐文件检查，只替换缺失或内容不符的文件。修复来源在管理程序 EXE 内，不依赖联网。
- 按保留的网络配置重新生成各勾选目录的单文件 `Scripts/Hooks/DcsEsportHook.lua`。已有同名文件在替换前备份；不修改同目录其他插件、DCS 配置、任务或游戏程序。
- 账号、网络凭据、选手池、队伍、比分、布局和 OBS 地址位于 `runtime`，不从安装包覆盖。损坏或丢失的网络凭据不会被静默重置，需恢复备份。
- 修复程序文件时，停止并恢复本安装拥有的服务；验证进程路径、PID 与启动时间，不按进程名称批量结束。主服务重启会释放内存遥测历史，比赛中应避免进行维护。
- 自动修复发生在点击启动前，另有“检查 / 修复”按钮；不在比赛中循环重装或重启。EXE 本身丢失 / 损坏时，重新运行分发的安装包并选择原目录。
- 原 HOOK 备份：`runtime/hook-originals`；修复替换文件备份：`runtime/repair-backups`。这些目录可能含本机凭据，不对外分发。
- 不跨目录联接 / 符号链接写入；遇到目录链接请选择它指向的实际位置。

## 构建与测试

先运行 `tools/fetch-dotnet.ps1` 下载固定微软离线包；脚本校验 SHA-256 和微软签名，不执行该安装包。再用 `python tools/build-installer.py --node <node.exe> --node-license <该版本完整官方 LICENSE>` 构建；可通过 `--dotnet` 指定同一已验证离线包。C++ 服务需预先构建，原生外层使用 MinGW x64 编译器与 windres 静态链接。白名单不复制开发机的 `runtime`、users.json、config.json 或已配置凭据的 HOOK。生成 SHA256SUMS.txt 和 build-manifest.json 记录外层、内层和 .NET 资源哈希。官方 Node.js 完整许可证随包分发。

外层提供只读 `--prereq-status --report <路径>` 检测报告；`--verify-bundle --report <路径>` 释放并验证内嵌资源而不执行 .NET 安装。`--bootstrap-cache <实际目录>` 指定可写缓存位置，主要用于隔离验收。其他参数原样传给内层安装器。

命令行支持 `/discover`、`/install`、`/verify`、`/repair`、`/start`、`/stop`，均可 `--report <绝对路径>` 输出不含密码的 JSON。维护命令用 `--root <安装路径>`；首次安装可重复 `--profile <DCS配置路径>`。自动化首次密码通过 `DCS_SETUP_PASSWORD` 环境变量传入，不写入参数或日志；`--no-integrate` 跳过桌面、开始菜单与注册表写入，仅用于隔离测试。`--http-port`、`--hook-port`、`--director-port` 可选择测试端口。

当前安装包未做代码签名。资料：微软 [Known Folder ID](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid)、[SHGetKnownFolderPath](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shgetknownfolderpath)。
