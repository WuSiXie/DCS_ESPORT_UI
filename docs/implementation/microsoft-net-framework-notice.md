# Microsoft .NET Framework 4.8 许可与来源说明

本项目提供 `NDP48-x86-x64-AllOS-ENU.exe`，作为 DCS 电竞 UI 安装管理程序的运行依赖。它是 Microsoft 发布的 .NET Framework 4.8 官方离线可再分发安装包，并非本项目原创软件。

## 许可归属

- .NET Framework 及安装包内的微软组件受其随附的 Microsoft 软件许可条款约束。完整条款以微软原版安装包随附内容为准；本说明不替代或修改这些条款。
- 本项目的 PolyForm Noncommercial 1.0.0 许可不适用于该微软安装包，也不向使用者授予额外的微软软件权利。
- 发布的微软 EXE 保持原始内容及 Microsoft Corporation 数字签名；未修改、重新签名或替换其中的许可文件。
- 本项目独立维护，不代表 Microsoft，也不表示获得 Microsoft 背书。

## 官方来源与核验

- [微软 .NET Framework 4.8 下载页面](https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48)
- [微软离线安装包原始下载链接](https://download.microsoft.com/download/f/3/a/f3a6af84-da23-40a5-8d1c-49cc10c8e76f/NDP48-x86-x64-AllOS-ENU.exe)
- [微软开发者部署指南](https://learn.microsoft.com/en-us/dotnet/framework/deployment/deployment-guide-for-developers)：说明离线可再分发包随应用部署及自行托管的方式。

文件大小：121,346,568 字节。

SHA-256：

```text
0a3a390c47e639d0f7fc65b21195fee6b7f65b066f80f70c60fab191d14b7e40
```

可以用 PowerShell 检查下载内容及原始签名：

```powershell
Get-FileHash .\NDP48-x86-x64-AllOS-ENU.exe -Algorithm SHA256
Get-AuthenticodeSignature .\NDP48-x86-x64-AllOS-ENU.exe
```

完整 DCS 电竞 UI 安装包已内置同一微软离线包，自动检测 .NET Framework 4.8 或更高版本，缺少时调用该包安装。Release 单独提供微软 EXE 作为备用下载，使用完整安装包通常无需再单独下载它。安装系统组件需要管理员权限；如要求重启，请重启后重新运行 DCS 电竞 UI 安装包。
