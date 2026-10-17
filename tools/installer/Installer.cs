using System;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DcsEsportSetup {
public class Profile { public string path {get;set;} public string originalBackup {get;set;} public string installedHash {get;set;} }
public class InstallState {
    public string product {get;set;} public string version {get;set;} public string root {get;set;}
    public int directorPort {get;set;} public List<Profile> profiles {get;set;}
}
public class Options {
    public string Root, Username, Password; public string[] Profiles = new string[0];
    public int HttpPort=9080, HookPort=9081, DirectorPort=9170;
    public bool Integrate=true;
}
public class Discovery { public string path {get;set;} public string source {get;set;} public string[] profiles {get;set;} }
public static class Folders {
    public const string SavedGamesId="{4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4}";
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
    public static string RegistryPath(string key) {
        using(var k=Registry.CurrentUser.OpenSubKey(key)) {
            var v=k==null?null:k.GetValue(SavedGamesId,null,RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            if(String.IsNullOrWhiteSpace(v)) return null;
            v=Environment.ExpandEnvironmentVariables(v);
            return Path.IsPathRooted(v)?Path.GetFullPath(v):null;
        }
    }
    public static Discovery Discover() {
        string path=null,source=null;
        foreach(var sub in new[]{"User Shell Folders","Shell Folders"}) {
            try {path=RegistryPath(@"Software\Microsoft\Windows\CurrentVersion\Explorer\"+sub);}catch(System.Security.SecurityException){}
            if(path!=null){source="注册表 / "+sub;break;}
        }
        if(path==null){IntPtr ptr=IntPtr.Zero;try {var id=new Guid(SavedGamesId);if(SHGetKnownFolderPath(ref id,0x4000,IntPtr.Zero,out ptr)==0){path=Marshal.PtrToStringUni(ptr);source="Windows Known Folder";}}finally{if(ptr!=IntPtr.Zero)Marshal.FreeCoTaskMem(ptr);}}
        if(String.IsNullOrEmpty(path)){path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),"Saved Games");source="用户目录回退 / 请核对";}
        return new Discovery{path=path,source=source,profiles=FindProfiles(path)};
    }
    public static string[] FindProfiles(string root) {
        if(!Directory.Exists(root))return new string[0];
        return Directory.GetDirectories(root).Where(p=>Path.GetFileName(p).StartsWith("DCS",StringComparison.OrdinalIgnoreCase)||File.Exists(Path.Combine(p,@"Config\options.lua"))).OrderBy(p=>p).ToArray();
    }
}
public static class Core {
    public const string Product="DCS-ESPORT-UI";
    public static readonly JavaScriptSerializer Json=new JavaScriptSerializer{MaxJsonLength=32*1024*1024};
    public static readonly Encoding Utf8=new UTF8Encoding(false);
    public static string Self {get{return Assembly.GetExecutingAssembly().Location;}}
    public static string ExeName="DCS电竞UI.exe";
    public static string DefaultRoot {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),@"Programs\DcsEsportUI");}}
    public static Action<string> Log=delegate{};
    public static string Full(string p) {if(String.IsNullOrWhiteSpace(p))throw new Exception("目录不能为空。");return Path.GetFullPath(p).TrimEnd(Path.DirectorySeparatorChar);}
    public static string Under(string root,string relative) {
        var p=Path.GetFullPath(Path.Combine(root,relative));
        if(!p.StartsWith(Full(root)+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new Exception("文件路径超出安装目录。");
        return p;
    }
    public static void NoLinks(string p) {
        for(var d=new DirectoryInfo(Path.GetDirectoryName(Path.GetFullPath(p)));d!=null;d=d.Parent)
            if(d.Exists&&(d.Attributes&FileAttributes.ReparsePoint)!=0)throw new Exception("目标包含目录链接，请选择真实目录："+d.FullName);
        if(File.Exists(p)&&(File.GetAttributes(p)&FileAttributes.ReparsePoint)!=0)throw new Exception("目标文件是链接："+p);
    }
    public static string Hash(byte[] b){using(var s=SHA256.Create())return BitConverter.ToString(s.ComputeHash(b)).Replace("-","").ToLowerInvariant();}
    public static string HashFile(string p){using(var s=SHA256.Create())using(var f=File.OpenRead(p))return BitConverter.ToString(s.ComputeHash(f)).Replace("-","").ToLowerInvariant();}
    public static string Token(int count){var b=new byte[count];using(var r=RandomNumberGenerator.Create())r.GetBytes(b);return BitConverter.ToString(b).Replace("-","").ToLowerInvariant();}
    public static T Read<T>(string p){return Json.Deserialize<T>(File.ReadAllText(p,Utf8));}
    public static void Atomic(string path,byte[] bytes) {
        NoLinks(path);Directory.CreateDirectory(Path.GetDirectoryName(path));var temp=path+".new-"+Guid.NewGuid().ToString("N");
        try {File.WriteAllBytes(temp,bytes);if(File.Exists(path))File.Replace(temp,path,null);else File.Move(temp,path);}finally{if(File.Exists(temp))File.Delete(temp);}
    }
    public static void Write(string path,object value){Atomic(path,Utf8.GetBytes(Json.Serialize(value)));}
    public static string StateFile(string root){return Under(root,@"runtime\installation.json");}
    public static InstallState State(string root) {
        var s=Read<InstallState>(StateFile(root));
        if(s==null||s.product!=Product||s.profiles==null||!String.Equals(Full(s.root),Full(root),StringComparison.OrdinalIgnoreCase))throw new Exception("安装记录无效；请保留 runtime 数据并使用原安装路径。");
        if(s.directorPort<1||s.directorPort>65535)throw new Exception("导播端口无效。");return s;
    }
    public static Dictionary<string,object> Config(string root) {
        var cfg=Read<Dictionary<string,object>>(Under(root,@"runtime\server\config.json"));
        foreach(var k in new[]{"hookToken","apiToken"})if(!cfg.ContainsKey(k)||!Regex.IsMatch(Convert.ToString(cfg[k]),"^[a-f0-9]{64}$"))throw new Exception("网络配置凭据无效；请从备份恢复，不会自动重置。");
        if(!cfg.ContainsKey("instanceId")||!Regex.IsMatch(Convert.ToString(cfg["instanceId"]),"^[a-zA-Z0-9_.-]{1,64}$"))throw new Exception("instanceId 无效。");
        Port(cfg,"hookPort");Port(cfg,"httpPort");if(Port(cfg,"hookPort")==Port(cfg,"httpPort"))throw new Exception("服务端口重复。");return cfg;
    }
    public static int Port(Dictionary<string,object> cfg,string key){int n=Convert.ToInt32(cfg[key]);if(n<1||n>65535)throw new Exception("端口无效："+key);return n;}
    public static Dictionary<string,string> Manifest(ZipArchive zip){using(var r=new StreamReader(zip.GetEntry("manifest.json").Open(),Utf8))return Json.Deserialize<Dictionary<string,string>>(r.ReadToEnd());}
    public static MemoryStream Payload() {
        var ms=new MemoryStream();using(var s=Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))s.CopyTo(ms);
        if(Hash(ms.ToArray())!=BuildInfo.PayloadHash)throw new Exception("安装包损坏，请重新获取安装包。");ms.Position=0;return ms;
    }
    public static byte[] Entry(ZipArchive zip,string key,string expected) {
        var e=zip.GetEntry(key);if(e==null)throw new Exception("安装包缺少文件："+key);
        using(var m=new MemoryStream()){using(var s=e.Open())s.CopyTo(m);var b=m.ToArray();if(Hash(b)!=expected)throw new Exception("安装包文件校验失败："+key);return b;}
    }
    public static byte[] Hook(string root) {
        var cfg=Config(root);var text=File.ReadAllText(Under(root,@"dist\DcsEsport\Scripts\Hooks\DcsEsportHook.lua"),Utf8);
        int end=text.IndexOf("-- END CONFIG",StringComparison.Ordinal);if(end<0)throw new Exception("HOOK 配置模板损坏。");
        string top=text.Substring(0,end);
        foreach(var key in new[]{"network = { enabled = false","port = 9081","instanceId = \"dcs-local\"","token = \"\""})if(!top.Contains(key))throw new Exception("HOOK 配置标记缺失。");
        top=top.Replace("network = { enabled = false","network = { enabled = true").Replace("port = 9081","port = "+Port(cfg,"hookPort")).Replace("instanceId = \"dcs-local\"","instanceId = \""+cfg["instanceId"]+"\"").Replace("token = \"\"","token = \""+cfg["hookToken"]+"\"");
        return Utf8.GetBytes(top+text.Substring(end));
    }
    static void Backup(string root,string file) {
        if(!File.Exists(file))return;
        var dest=Under(root,@"runtime\repair-backups\"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")+"-"+Path.GetFileName(file));
        NoLinks(dest);Directory.CreateDirectory(Path.GetDirectoryName(dest));File.Copy(file,dest);Log("已备份被替换文件："+Path.GetFileName(file));
    }
    static void DeployHook(string root,InstallState s) {
        var bytes=Hook(root);var hash=Hash(bytes);
        foreach(var p in s.profiles) {
            if(!Directory.Exists(p.path))throw new Exception("DCS 配置目录不存在，请恢复目录或重新选择："+p.path);
            var dest=Under(p.path,@"Scripts\Hooks\DcsEsportHook.lua");NoLinks(dest);
            if(File.Exists(dest)&&HashFile(dest)==hash){p.installedHash=hash;continue;}
            if(p.installedHash==null&&File.Exists(dest)) {
                p.originalBackup=Under(root,@"runtime\hook-originals\"+Guid.NewGuid().ToString("N")+".lua");Atomic(p.originalBackup,File.ReadAllBytes(dest));
                Write(StateFile(root),s);
            }
            Backup(root,dest);Atomic(dest,bytes);p.installedHash=hash;Write(StateFile(root),s);
            Log("HOOK 已安装 / 修复："+p.path+"（重启 DCS 后生效）");
        }
        Atomic(Under(root,@"runtime\deploy\DcsEsportHook.lua"),bytes);
    }
    public static void ValidateProfiles(string[] paths) {
        foreach(var path in paths) {
            if(!Directory.Exists(path)||Full(path)==Path.GetPathRoot(Full(path)).TrimEnd('\\'))throw new Exception("请选择已存在的 DCS 配置目录。");
            if(File.Exists(Path.Combine(path,@"bin\DCS.exe")))throw new Exception("应选择保存的游戏内的 DCS 配置目录，而不是 DCS 游戏安装目录。");
            NoLinks(Under(path,@"Scripts\Hooks\DcsEsportHook.lua"));
        }
    }
    public static void Install(Options o) {
        o.Root=Full(o.Root);NoLinks(Under(o.Root,"placeholder"));ValidateProfiles(o.Profiles);
        bool existing=File.Exists(StateFile(o.Root));
        if(Directory.Exists(o.Root)&&Directory.EnumerateFileSystemEntries(o.Root).Any()&&!existing)throw new Exception("目标非空且不是本安装器管理的目录。请选择新的安装目录，避免覆盖现有项目。");
        if(o.Profiles.Any(p=>Full(p).StartsWith(o.Root+"\\",StringComparison.OrdinalIgnoreCase)||o.Root.StartsWith(Full(p)+"\\",StringComparison.OrdinalIgnoreCase)||Full(p)==o.Root))throw new Exception("程序目录与 DCS 配置目录不能重叠。");
        if(!existing) {
            if(!Regex.IsMatch(o.Username??"","^[a-zA-Z0-9_.-]{2,64}$")||(o.Password??"").Length<12||(o.Password??"").Length>256)throw new Exception("账号需为 2-64 位英文/数字/_.-；密码为 12-256 字符。");
            if(new[]{o.HttpPort,o.HookPort,o.DirectorPort}.Any(p=>p<1||p>65535)||new[]{o.HttpPort,o.HookPort,o.DirectorPort}.Distinct().Count()!=3)throw new Exception("三个端口必须有效且不同。");
        }
        var s=existing?State(o.Root):new InstallState{product=Product,version=BuildInfo.Version,root=o.Root,directorPort=o.DirectorPort,profiles=new List<Profile>()};
        if(existing){Config(o.Root);Log("已有账号、网络凭据与输出配置将保留。");}
        Directory.CreateDirectory(o.Root);
        if(!existing) {
            var cfg=new Dictionary<string,object>{{"instanceId","dcs-local"},{"hookPort",o.HookPort},{"httpPort",o.HttpPort},{"hookToken",Token(32)},{"apiToken",Token(32)}};
            Write(Under(o.Root,@"runtime\server\config.json"),cfg);
            var salt=new byte[16];using(var rng=RandomNumberGenerator.Create())rng.GetBytes(salt);
            byte[] key;using(var derive=new Rfc2898DeriveBytes(o.Password,salt,600000,HashAlgorithmName.SHA256))key=derive.GetBytes(32);
            Func<byte[],string> hex=b=>BitConverter.ToString(b).Replace("-","").ToLowerInvariant();
            Write(Under(o.Root,@"runtime\server\users.json"),new{version=1,users=new[]{new{username=o.Username,role="director",enabled=true,instances=new[]{"dcs-local"},password=new{algorithm="pbkdf2-sha256",iterations=600000,salt=hex(salt),hash=hex(key)}}}});
            Write(StateFile(o.Root),s);
        }
        s.profiles=o.Profiles.Select(Full).Distinct(StringComparer.OrdinalIgnoreCase).Select(p=>s.profiles.FirstOrDefault(x=>String.Equals(x.path,p,StringComparison.OrdinalIgnoreCase))??new Profile{path=p}).ToList();
        Write(StateFile(o.Root),s);
        Repair(o.Root);
        var installed=Under(o.Root,ExeName);
        if(!String.Equals(Self,installed,StringComparison.OrdinalIgnoreCase)&&(!File.Exists(installed)||HashFile(Self)!=HashFile(installed)))Atomic(installed,File.ReadAllBytes(Self));
        if(o.Integrate)Integrate(o.Root);
        Log("安装完成。可从桌面或开始菜单启动；首次登录使用安装时设置的账号。");
    }
    public static List<string> Verify(string root) {
        var s=State(root);Config(root);var bad=new List<string>();
        using(var stream=Payload())using(var zip=new ZipArchive(stream,ZipArchiveMode.Read)) {
            foreach(var item in Manifest(zip)){var path=Under(root,item.Key);NoLinks(path);if(!File.Exists(path)||HashFile(path)!=item.Value)bad.Add(item.Key);}
        }
        if(!bad.Any(x=>x.StartsWith("dist/DcsEsport/"))) {
            var hash=Hash(Hook(root));foreach(var p in s.profiles){var dest=Under(p.path,@"Scripts\Hooks\DcsEsportHook.lua");NoLinks(dest);if(!File.Exists(dest)||HashFile(dest)!=hash)bad.Add("HOOK: "+p.path);}
        }
        return bad;
    }
    public static void Repair(string root) {
        var s=State(root);Config(root);ValidateProfiles(s.profiles.Select(p=>p.path).ToArray());
        var repair=new List<KeyValuePair<string,byte[]>>();
        using(var stream=Payload())using(var zip=new ZipArchive(stream,ZipArchiveMode.Read)) {
            foreach(var item in Manifest(zip)) {var path=Under(root,item.Key);NoLinks(path);if(!File.Exists(path)||HashFile(path)!=item.Value)repair.Add(new KeyValuePair<string,byte[]>(path,Entry(zip,item.Key,item.Value)));}
        }
        bool hadServer=false,hadDirector=false;
        if(repair.Count>0){hadDirector=Owned(root,false)!=null;hadServer=Owned(root,true)!=null;Stop(root);}
        try {
            foreach(var item in repair){Backup(root,item.Key);Atomic(item.Key,item.Value);Log("已恢复："+item.Key.Substring(root.Length+1));}
            DeployHook(root,s);s.version=BuildInfo.Version;Write(StateFile(root),s);
            var manager=Under(root,ExeName);if(!File.Exists(manager))Atomic(manager,File.ReadAllBytes(Self));
            var remaining=Verify(root);if(remaining.Count>0)throw new Exception("修复后仍有校验失败："+String.Join(", ",remaining));
            Log("完整性检查通过；账号、输出布局与读取地址已保留。");
        } finally {
            if(hadServer)StartOne(root,true);if(hadDirector)StartOne(root,false);
        }
    }
    static string ProcessFile(string root,bool main){return Under(root,main?@"runtime\server\process.json":@"runtime\director-"+State(root).directorPort+@"\process.json");}
    static string ProcessExe(string root,bool main){return Under(root,main?@"dist\server\dcs-esport-server.exe":@"runtime-bin\node.exe");}
    public static Process Owned(string root,bool main) {
        var file=ProcessFile(root,main);if(!File.Exists(file))return null;
        try {
            var v=Read<Dictionary<string,object>>(file);var p=Process.GetProcessById(Convert.ToInt32(v["processId"]));
            if(String.Equals(p.MainModule.FileName,ProcessExe(root,main),StringComparison.OrdinalIgnoreCase)&&p.StartTime.ToUniversalTime().Ticks.ToString()==Convert.ToString(v["startedTicks"]))return p;
        }catch(ArgumentException){}catch(InvalidOperationException){}catch(System.ComponentModel.Win32Exception){}catch(KeyNotFoundException){}
        return null;
    }
    public static void Stop(string root) {
        foreach(bool main in new[]{false,true}){var p=Owned(root,main);if(p==null)continue;p.Kill();if(!p.WaitForExit(5000))throw new Exception("进程未能停止，请稍后重试。");Log(main?"主服务已停止（内存遥测历史已释放）。":"导播服务已停止。");}
    }
    static bool FreePort(int port){try{var l=new TcpListener(IPAddress.Loopback,port);l.Start();l.Stop();return true;}catch(SocketException){return false;}}
    static string Quote(string s){if(s.Contains("\"")||s.Contains("\r")||s.Contains("\n"))throw new Exception("路径包含非法字符。");return "\""+s+"\"";}
    static bool Health(int port){try{var req=(HttpWebRequest)WebRequest.Create("http://127.0.0.1:"+port+"/healthz");req.Timeout=800;using(var r=req.GetResponse())using(var sr=new StreamReader(r.GetResponseStream()))return sr.ReadToEnd().Contains("ok");}catch(WebException){return false;}}
    public static void StartOne(string root,bool main) {
        var cfg=Config(root);var state=State(root);int port=main?Port(cfg,"httpPort"):state.directorPort;
        var owned=Owned(root,main);if(owned!=null){if(!Health(port))throw new Exception("本安装的服务进程存在但未就绪，请查看日志后停止并重试。");Log(main?"主服务已运行。":"导播已运行。");return;}
        if(!FreePort(port)||(main&&!FreePort(Port(cfg,"hookPort"))))throw new Exception("端口 "+port+" 或 HOOK 端口已被占用；不会终止其他程序，请选择其他端口或停止原服务。");
        string dir=Under(root,main?@"runtime\server":@"runtime\director-"+port);Directory.CreateDirectory(dir);
        var si=new ProcessStartInfo(ProcessExe(root,main)){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=root};
        if(main) {
            // Keep the native server's file arguments ASCII-relative to its Unicode working directory.
            si.Arguments="--port "+Port(cfg,"hookPort")+" --http-port "+port+" --instance "+Quote(Convert.ToString(cfg["instanceId"]))+" --users runtime/server/users.json";
            si.EnvironmentVariables["DCS_ESPORT_HOOK_TOKEN"]=Convert.ToString(cfg["hookToken"]);si.EnvironmentVariables["DCS_ESPORT_API_TOKEN"]=Convert.ToString(cfg["apiToken"]);
            if(cfg.ContainsKey("tlsPort")) {
                var cert=Under(root,Convert.ToString(cfg["tlsCertificate"]));var key=Under(root,Convert.ToString(cfg["tlsKey"]));
                si.Arguments+=" --tls-port "+Port(cfg,"tlsPort")+" --tls-bind "+Quote(cfg.ContainsKey("tlsBind")?Convert.ToString(cfg["tlsBind"]):"127.0.0.1")+" --tls-cert "+Quote(cert)+" --tls-key "+Quote(key);
            }
        } else si.Arguments=Quote(Under(root,@"src\director\server.mjs"))+" --port "+port+" --upstream http://127.0.0.1:"+Port(cfg,"httpPort")+" --data-dir "+Quote(dir);
        // A dedicated hidden child owns log redirection so logs survive closing the manager.
        var descriptor=new Dictionary<string,object>{{"executable",si.FileName},{"arguments",si.Arguments},{"directory",dir},{"workingDirectory",root},{"main",main}};
        // Secrets are inherited by the logger child, never put into argv or the descriptor.
        var launcher=new ProcessStartInfo(Self,"/host --root "+Quote(root)+" --kind "+(main?"server":"director")){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=root};
        if(main){launcher.EnvironmentVariables["DCS_ESPORT_HOOK_TOKEN"]=si.EnvironmentVariables["DCS_ESPORT_HOOK_TOKEN"];launcher.EnvironmentVariables["DCS_ESPORT_API_TOKEN"]=si.EnvironmentVariables["DCS_ESPORT_API_TOKEN"];}
        Write(Under(dir,"launch.json"),descriptor);
        var host=Process.Start(launcher);
        for(int i=0;i<60;i++){Thread.Sleep(100);if(Owned(root,main)!=null&&Health(port)){Log(main?"主服务就绪。":"导播就绪。");return;}if(host.HasExited)break;}
        var failed=Owned(root,main);if(failed!=null){failed.Kill();failed.WaitForExit(5000);}
        throw new Exception("服务启动失败，查看 "+dir+@"\stderr.log");
    }
    public static void Host(string root,bool main) {
        var dir=Under(root,main?@"runtime\server":@"runtime\director-"+State(root).directorPort);
        var d=Read<Dictionary<string,object>>(Under(dir,"launch.json"));
        var exe=ProcessExe(root,main);if(Convert.ToString(d["executable"])!=exe)throw new Exception("启动记录不匹配。");
        var si=new ProcessStartInfo(exe,Convert.ToString(d["arguments"])){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=root,RedirectStandardOutput=true,RedirectStandardError=true};
        using(var output=new StreamWriter(Under(dir,"stdout.log"),true,Utf8))using(var error=new StreamWriter(Under(dir,"stderr.log"),true,Utf8))using(var p=new Process{StartInfo=si}) {
            output.AutoFlush=true;error.AutoFlush=true;
            p.OutputDataReceived+=(a,b)=>{if(b.Data!=null){lock(output)output.WriteLine(b.Data);}};
            p.ErrorDataReceived+=(a,b)=>{if(b.Data!=null){lock(error)error.WriteLine(b.Data);}};
            p.Start();Write(ProcessFile(root,main),new{processId=p.Id,startedTicks=p.StartTime.ToUniversalTime().Ticks.ToString(),executable=exe,entry=main?null:Under(root,@"src\director\server.mjs")});
            p.BeginOutputReadLine();p.BeginErrorReadLine();p.WaitForExit();
        }
    }
    public static void Start(string root){Repair(root);StartOne(root,true);StartOne(root,false);}
    public static void Exclusive(string root,Action job) {
        using(var mutex=new Mutex(false,@"Local\DcsEsport-"+Hash(Utf8.GetBytes(Full(root).ToUpperInvariant())).Substring(0,20))) {
            bool taken=false;try {try{taken=mutex.WaitOne(0);}catch(AbandonedMutexException){taken=true;}
                if(!taken)throw new Exception("该安装正在执行其他维护操作。");job();
            }finally{if(taken)mutex.ReleaseMutex();}
        }
    }
    public static void Integrate(string root) {
        string exe=Under(root,ExeName);
        foreach(var baseDir in new[]{Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs),"DCS 电竞 UI")}) {
            Directory.CreateDirectory(baseDir);Shortcut(Path.Combine(baseDir,"DCS 电竞 UI.lnk"),exe,root);
        }
        using(var k=Registry.CurrentUser.CreateSubKey(@"Software\DcsEsportUI")){k.SetValue("InstallLocation",root);k.SetValue("Version",BuildInfo.Version);}
        Log("桌面与开始菜单入口已创建。");
    }
    public static void Shortcut(string file,string exe,string root) {
        dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
        try {dynamic link=shell.CreateShortcut(file);try{link.TargetPath=exe;link.Arguments="/manage";link.WorkingDirectory=root;link.Description="启动、自动修复与管理 DCS 电竞 UI";link.Save();}finally{Marshal.FinalReleaseComObject(link);}}
        finally{Marshal.FinalReleaseComObject(shell);}
    }
}
public class SetupForm:Form {
    TextBox root=new TextBox(),saved=new TextBox(),user=new TextBox(),password=new TextBox(),confirm=new TextBox(),log=new TextBox();
    CheckedListBox profiles=new CheckedListBox();Label detected=new Label();NumericUpDown http=new NumericUpDown(),hook=new NumericUpDown(),director=new NumericUpDown();
    FlowLayoutPanel actions=new FlowLayoutPanel();bool busy;string installedRoot;
    public SetupForm(string manageRoot) {
        Text="DCS 电竞 UI - 安装与维护 0.8.0";Width=830;Height=850;MinimumSize=new Size(780,780);StartPosition=FormStartPosition.CenterScreen;
        Font=new Font("Microsoft YaHei UI",9);BackColor=Color.FromArgb(245,248,250);AutoScaleMode=AutoScaleMode.Dpi;
        var panel=new TableLayoutPanel{Dock=DockStyle.Fill,Padding=new Padding(24),ColumnCount=3,RowCount=14};panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,120));panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));panel.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,110));Controls.Add(panel);
        Action<int,string,Control> row=(i,name,control)=>{panel.Controls.Add(new Label{Text=name,AutoSize=true,Margin=new Padding(0,8,5,5)},0,i);control.Dock=DockStyle.Fill;control.Margin=new Padding(3,5,3,5);panel.Controls.Add(control,1,i);};
        var title=new Label{Text="安装一次，启动时自动检查与修复",AutoSize=true,Font=new Font(Font.FontFamily,17,FontStyle.Bold),ForeColor=Color.FromArgb(0,118,111),Margin=new Padding(0,0,0,18)};panel.Controls.Add(title,0,0);panel.SetColumnSpan(title,3);
        row(1,"程序安装目录",root);root.Text=manageRoot??Core.DefaultRoot;
        var choose=new Button{Text="浏览…",Dock=DockStyle.Fill};panel.Controls.Add(choose,2,1);choose.Click+=(a,b)=>Browse(root);
        row(2,"保存的游戏根目录",saved);var scan=new Button{Text="选择 / 扫描",Dock=DockStyle.Fill};panel.Controls.Add(scan,2,2);scan.Click+=(a,b)=>{Browse(saved);Scan();};
        panel.Controls.Add(detected,1,3);panel.SetColumnSpan(detected,2);detected.AutoSize=true;detected.ForeColor=Color.DimGray;
        row(4,"安装 HOOK 到",profiles);profiles.Height=95;profiles.CheckOnClick=true;
        var manual=new Button{Text="添加配置目录",Dock=DockStyle.Top};panel.Controls.Add(manual,2,4);manual.Click+=(a,b)=>{using(var d=new FolderBrowserDialog{Description="选择 DCS 配置目录（含 Config / Scripts），不是游戏安装目录"})if(d.ShowDialog()==DialogResult.OK&&!profiles.Items.Contains(d.SelectedPath))profiles.Items.Add(d.SelectedPath,true);};
        row(5,"首次登录账号",user);user.Text="director";row(6,"首次登录密码",password);password.UseSystemPasswordChar=true;row(7,"再次输入密码",confirm);confirm.UseSystemPasswordChar=true;
        var ports=new FlowLayoutPanel{AutoSize=true};foreach(var pair in new[]{Tuple.Create("HTTP",http,9080),Tuple.Create("HOOK",hook,9081),Tuple.Create("导播",director,9170)}){ports.Controls.Add(new Label{Text=pair.Item1,AutoSize=true,Margin=new Padding(3,7,3,3)});pair.Item2.Minimum=1;pair.Item2.Maximum=65535;pair.Item2.Value=pair.Item3;pair.Item2.Width=82;ports.Controls.Add(pair.Item2);}row(8,"首次安装端口",ports);panel.SetColumnSpan(ports,2);
        var hint=new Label{AutoSize=true,Text="密码需 12-256 字符。修复保留账号、队伍与 OBS 地址；修复程序文件可能重启本安装的服务。\nHOOK 更新后需重启 DCS。取消勾选只停止维护该目录，不删除旧 HOOK。",ForeColor=Color.DimGray,Margin=new Padding(0,10,0,12)};panel.Controls.Add(hint,0,9);panel.SetColumnSpan(hint,3);
        panel.Controls.Add(actions,0,10);panel.SetColumnSpan(actions,3);actions.AutoSize=true;
        Add("安装 / 更新",()=>{if(!File.Exists(Core.StateFile(root.Text))&&password.Text!=confirm.Text)throw new Exception("两次密码不一致。");var o=new Options{Root=root.Text,Profiles=profiles.CheckedItems.Cast<string>().ToArray(),Username=user.Text,Password=password.Text,HttpPort=(int)http.Value,HookPort=(int)hook.Value,DirectorPort=(int)director.Value};return ()=>{Core.Install(o);installedRoot=o.Root;};});
        Add("启动并打开",()=>{var r=root.Text;return ()=>{Core.Start(r);Open("http://127.0.0.1:"+Core.State(r).directorPort+"/");};});
        Add("检查 / 修复",()=>{var r=root.Text;return ()=>Core.Repair(r);});Add("停止服务",()=>{var r=root.Text;return ()=>Core.Stop(r);});
        Add("使用说明",()=>{var r=root.Text;return ()=>Open(Core.Under(r,@"docs\使用说明.pdf"));});Add("日志目录",()=>{var r=root.Text;return ()=>Open(Core.Under(r,"runtime"));});
        log.Multiline=true;log.ReadOnly=true;log.ScrollBars=ScrollBars.Vertical;log.Dock=DockStyle.Fill;log.BackColor=Color.White;panel.Controls.Add(log,0,11);panel.SetColumnSpan(log,3);panel.RowStyles.Clear();for(int i=0;i<11;i++)panel.RowStyles.Add(new RowStyle(SizeType.AutoSize));panel.RowStyles.Add(new RowStyle(SizeType.Percent,100));
        Core.Log=msg=>{if(IsHandleCreated&&!IsDisposed)BeginInvoke((Action)(()=>log.AppendText(DateTime.Now.ToString("HH:mm:ss")+"  "+msg+Environment.NewLine)));};
        var found=Folders.Discover();saved.Text=found.path;detected.Text="识别来源："+found.source;Scan();
        if(manageRoot!=null){installedRoot=manageRoot;var s=Core.State(manageRoot);profiles.Items.Clear();foreach(var p in s.profiles)profiles.Items.Add(p.path,true);var cfg=Core.Config(manageRoot);http.Value=Core.Port(cfg,"httpPort");hook.Value=Core.Port(cfg,"hookPort");director.Value=s.directorPort;user.Enabled=password.Enabled=confirm.Enabled=http.Enabled=hook.Enabled=director.Enabled=false;detected.Text+="；已有安装将保留原账号与端口。";}
        root.TextChanged+=(a,b)=>{try{bool fresh=!File.Exists(Core.StateFile(root.Text));user.Enabled=password.Enabled=confirm.Enabled=http.Enabled=hook.Enabled=director.Enabled=fresh;}catch(ArgumentException){}};
        FormClosing+=(a,b)=>{if(busy){b.Cancel=true;MessageBox.Show("正在执行，请等待完成。","DCS 电竞 UI");}};
    }
    void Scan(){profiles.Items.Clear();foreach(var p in Folders.FindProfiles(saved.Text))profiles.Items.Add(p,Path.GetFileName(p).Equals("DCS",StringComparison.OrdinalIgnoreCase));}
    void Browse(TextBox box){using(var d=new FolderBrowserDialog{SelectedPath=Directory.Exists(box.Text)?box.Text:""})if(d.ShowDialog()==DialogResult.OK)box.Text=d.SelectedPath;}
    void Add(string text,Func<Action> prepare){var b=new Button{Text=text,AutoSize=true,Height=34,Margin=new Padding(0,0,9,8)};actions.Controls.Add(b);b.Click+=async(a,e)=>{try{Action job=prepare();var r=root.Text;busy=true;actions.Enabled=false;await Task.Run(()=>Core.Exclusive(r,job));}catch(Exception ex){log.AppendText("失败："+ex.Message+Environment.NewLine);MessageBox.Show(ex.Message,"操作未完成",MessageBoxButtons.OK,MessageBoxIcon.Error);}finally{busy=false;actions.Enabled=true;password.Clear();confirm.Clear();}};}
    static void Open(string p){Process.Start(new ProcessStartInfo(p){UseShellExecute=true});}
}
public static class Program {
    static string Arg(string[] a,string key,string fallback=null){int i=Array.IndexOf(a,key);return i>=0&&i+1<a.Length?a[i+1]:fallback;}
    [STAThread] public static int Main(string[] args) {
        string report=Arg(args,"--report"),mode=args.Length>0?args[0]:"";
        try {
            if(mode=="/discover"){var data=Folders.Discover();if(report!=null)Core.Write(report,data);return 0;}
            string root=Arg(args,"--root",Path.GetDirectoryName(Core.Self));
            if(mode=="/host"){Core.Host(root,Arg(args,"--kind")=="server");return 0;}
            if(new[]{"/install","/repair","/verify","/start","/stop"}.Contains(mode)) {
                var logs=new List<string>();Core.Log=s=>logs.Add(s);
                Core.Exclusive(root,()=>{
                        if(mode=="/install") {var o=new Options{Root=root,Username=Arg(args,"--username","director"),Password=Environment.GetEnvironmentVariable("DCS_SETUP_PASSWORD"),Profiles=args.Where((x,i)=>i>0&&args[i-1]=="--profile").ToArray(),HttpPort=int.Parse(Arg(args,"--http-port","9080")),HookPort=int.Parse(Arg(args,"--hook-port","9081")),DirectorPort=int.Parse(Arg(args,"--director-port","9170")),Integrate=!args.Contains("--no-integrate")};Core.Install(o);}
                        else if(mode=="/repair")Core.Repair(root);
                        else if(mode=="/start")Core.Start(root);
                        else if(mode=="/stop")Core.Stop(root);
                        else {var bad=Core.Verify(root);if(bad.Count>0)throw new Exception("校验失败："+String.Join(", ",bad));}
                });
                if(report!=null)Core.Write(report,new{ok=true,mode=mode,logs=logs});return 0;
            }
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            var own=Path.GetDirectoryName(Core.Self);string installed=File.Exists(Core.StateFile(own))?own:null;
            // The distributed setup can discover a prior per-user installation.
            if(installed==null)using(var k=Registry.CurrentUser.OpenSubKey(@"Software\DcsEsportUI")){var p=k==null?null:k.GetValue("InstallLocation") as string;if(p!=null&&File.Exists(Core.StateFile(p)))installed=p;}
            Application.Run(new SetupForm(installed));return 0;
        } catch(Exception ex) {
            if(report!=null){Core.Write(report,new{ok=false,error=ex.Message});return 1;}
            if(mode!="/host")MessageBox.Show(ex.Message,"DCS 电竞 UI",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;
        }
    }
}
}
