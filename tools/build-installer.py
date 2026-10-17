"""Build the offline Windows x64 setup from an explicit, credential-free allowlist."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--node', type=Path, default=Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe')
    ap.add_argument('--node-license', type=Path, default=ROOT/'build/installer/Node-LICENSE.txt')
    ap.add_argument('--dotnet', type=Path, default=ROOT/'.tools/prerequisites/NDP48-x86-x64-AllOS-ENU.exe')
    a=ap.parse_args()
    node_version=subprocess.check_output([str(a.node),'--version'],text=True).strip()
    if int(node_version.removeprefix('v').split('.')[0])<24: raise ValueError('Node.js 24+ required')
    if not a.node_license.is_file() or a.node_license.stat().st_size<10000: raise ValueError('Supply the complete official Node.js LICENSE including third-party notices.')
    powershell=Path(os.environ.get('WINDIR',r'C:\Windows'))/'System32/WindowsPowerShell/v1.0/powershell.exe'
    prerequisite=json.loads(subprocess.check_output([str(powershell),'-NoProfile','-ExecutionPolicy','Bypass','-File',str(ROOT/'tools/fetch-dotnet.ps1'),'-Path',str(a.dotnet),'-VerifyOnly'],text=True))
    for tool in ['package.py','package-director.py']: subprocess.run([sys.executable,str(ROOT/'tools'/tool)],check=True)
    files={}
    for f in (ROOT/'dist/server').iterdir():
        if f.name in {'dcs-esport-server.exe','LICENSE_1_0.txt','OpenSSL-LICENSE.txt'}: files['dist/server/'+f.name]=f
    if 'dist/server/dcs-esport-server.exe' not in files: raise ValueError('Build the C++ server first')
    for folder in ['director','web']:
        for f in (ROOT/'src'/folder).iterdir():
            if f.suffix in {'.mjs','.html','.css'}: files[f'src/{folder}/{f.name}']=f
    files['dist/DcsEsport/Scripts/Hooks/DcsEsportHook.lua']=ROOT/'dist/DcsEsport/Scripts/Hooks/DcsEsportHook.lua'
    files['runtime-bin/node.exe']=a.node
    files['licenses/Node-LICENSE.txt']=a.node_license
    files['docs/使用说明.pdf']=ROOT/'output/pdf/DCS电竞UI使用说明.pdf'
    for name in ['Server.ps1','Director.ps1','Configure-Network.ps1','install.ps1','accounts.py']:
        files['tools/'+name]=ROOT/'tools'/name
    for name in ['director','server','mission-hook','installer']:
        files['docs/implementation/'+name+'.md']=ROOT/'docs/implementation'/f'{name}.md'
    work=ROOT/'build/installer';work.mkdir(parents=True,exist_ok=True)
    archive=work/'payload.zip'
    manifest={k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in sorted(files.items())}
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for k,v in sorted(files.items()):z.writestr(k,v.read_bytes())
        z.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False))
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    (work/'BuildInfo.cs').write_text('namespace DcsEsportSetup { public static class BuildInfo { public const string Version="0.8.0"; public const string PayloadHash="'+digest+'"; } }',encoding='utf-8')
    out=ROOT/'dist/installer';out.mkdir(parents=True,exist_ok=True)
    exe=out/'DCS-Esport-UI-Setup-0.8.0.exe'
    manager=work/'DcsEsportManager.exe'
    compiler=Path(os.environ.get('WINDIR',r'C:\Windows'))/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    cmd=[str(compiler),'/nologo','/target:winexe','/platform:x64','/optimize+',f'/out:{manager}',
         '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Web.Extensions.dll',
         '/reference:System.IO.Compression.dll','/reference:System.IO.Compression.FileSystem.dll','/reference:Microsoft.CSharp.dll',
         f'/resource:{archive},payload.zip',str(ROOT/'tools/installer/Installer.cs'),str(work/'BuildInfo.cs')]
    subprocess.run(cmd,check=True)
    manager_hash=hashlib.sha256(manager.read_bytes()).hexdigest()
    (work/'BootstrapInfo.hpp').write_text('#pragma once\n#include <string>\nnamespace bootstrap_info {\ninline const std::string manager_hash="'+manager_hash+'";\ninline const std::string dotnet_hash="'+prerequisite['sha256']+'";\n}\n',encoding='utf-8')
    def rc_path(path):return str(path.resolve()).replace('\\','/')
    (work/'bootstrap.rc').write_text('101 RCDATA "'+rc_path(manager)+'"\n102 RCDATA "'+rc_path(a.dotnet)+'"\n1 24 "'+rc_path(ROOT/'tools/installer/bootstrap.manifest')+'"\n',encoding='utf-8')
    native=Path('C:/msys64/ucrt64/bin')
    env=os.environ.copy();env['PATH']=str(native)+os.pathsep+env.get('PATH','')
    subprocess.run([str(native/'windres.exe'),'-i',str(work/'bootstrap.rc'),'-o',str(work/'bootstrap-res.o')],env=env,check=True)
    subprocess.run([str(native/'g++.exe'),'-std=c++17','-O2','-s','-Wall','-Wextra','-municode','-mwindows','-static','-static-libgcc','-static-libstdc++',
                    '-I'+str(work),str(ROOT/'tools/installer/Bootstrap.cpp'),str(work/'bootstrap-res.o'),'-o',str(exe),
                    '-lbcrypt','-lwintrust','-lcrypt32','-lshell32','-lole32','-luuid','-ladvapi32'],env=env,check=True)
    result={'version':'0.8.0','bootstrapRevision':1,'nativeBootstrap':True,'minimumFrameworkRelease':528040,'dotnet':prerequisite,
            'managerSha256':manager_hash,'node':node_version,'installer':exe.name,'sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'bytes':exe.stat().st_size,'payloadSha256':digest,'files':manifest}
    (out/'build-manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (out/'SHA256SUMS.txt').write_text(result['sha256']+'  '+exe.name+'\n',encoding='ascii')
    (out/'安装说明.txt').write_text('DCS 电竞 UI 0.8.0 离线安装包\n\n双击 EXE，先自动检测 .NET Framework 4.8 或更高版本。缺少时运行内置的微软官方离线安装包；Windows 会要求管理员授权。无需另行下载 .NET。\n系统要求重启时，不会强制重启；请自行重启后再次运行本安装包。取消授权或安装失败时不会继续安装项目。\n环境就绪后选择程序目录和 DCS 配置目录，设置首次账号密码，点击“安装 / 更新”。\n安装后通过桌面入口点击“启动并打开”。每次启动前会自动校验和修复程序及 HOOK。\n也可点击“检查 / 修复”，或重新运行本安装包修复。\n支持注册表识别保存的游戏目录、多 DCS 配置目录和手动选择。\n不会自动启动 DCS；安装或更新 HOOK 后，请重启 DCS。\n修复保留账号、网络凭据、队伍、布局和 OBS 地址。\n完整使用说明及安装维护说明位于安装目录 docs。\nWindows 10/11 x64；内置 Node.js，运行无需 Python。\n外层安装包未做代码签名；内置 .NET 安装包保留微软数字签名。\n',encoding='utf-8-sig')
    print(json.dumps({k:v for k,v in result.items() if k!='files'},indent=2))

if __name__=='__main__':main()
