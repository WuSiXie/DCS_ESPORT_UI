using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using DcsEsportSetup;
class InstallerProbe {
    [STAThread] static int Main(string[] args) {
        var output=Path.GetFullPath(args[0]);Directory.CreateDirectory(output);
        var key=@"Software\DcsEsportUI-InstallerTests-"+Guid.NewGuid().ToString("N");
        try {
            Environment.SetEnvironmentVariable("DCS_SAVED_GAMES_FIXTURE",Path.Combine(output,"重定向的保存游戏"));
            using(var k=Registry.CurrentUser.CreateSubKey(key))k.SetValue(Folders.SavedGamesId,@"%DCS_SAVED_GAMES_FIXTURE%",RegistryValueKind.ExpandString);
            var found=Folders.RegistryPath(key);
            if(found!=Environment.GetEnvironmentVariable("DCS_SAVED_GAMES_FIXTURE"))throw new Exception("Registry expansion failed");
            Directory.CreateDirectory(Path.Combine(found,"DCS"));Directory.CreateDirectory(Path.Combine(found,"DCS.openbeta"));Directory.CreateDirectory(Path.Combine(found,"custom-flight","Config"));
            File.WriteAllText(Path.Combine(found,@"custom-flight\Config\options.lua"),"-- fixture");
            Directory.CreateDirectory(Path.Combine(found,"unrelated"));
            if(Folders.FindProfiles(found).Length!=3)throw new Exception("Profile detection failed");
            using(var k=Registry.CurrentUser.OpenSubKey(key,true))k.SetValue(Folders.SavedGamesId,"relative-directory");
            if(Folders.RegistryPath(key)!=null)throw new Exception("Relative registry path accepted");
            string shortcut=Path.Combine(output,"快捷方式测试.lnk");Core.Shortcut(shortcut,Core.Self,Path.GetDirectoryName(Core.Self));
            dynamic shell=Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));dynamic link=shell.CreateShortcut(shortcut);
            if(link.TargetPath!=Core.Self||link.Arguments!="/manage")throw new Exception("Shortcut target incorrect");
            Marshal.FinalReleaseComObject(link);Marshal.FinalReleaseComObject(shell);
            Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
            using(var form=new SetupForm(null)) {
                form.Opacity=0;form.ShowInTaskbar=false;form.Show();Application.DoEvents();form.PerformLayout();
                using(var bitmap=new Bitmap(form.Width,form.Height)){form.DrawToBitmap(bitmap,new Rectangle(0,0,form.Width,form.Height));bitmap.Save(Path.Combine(output,"installer-ui.png"));}
                form.Close();
            }
            Core.Write(Path.Combine(output,"probe.json"),new{ok=true,registryRedirect=true,environmentExpansion=true,profileDetection=true,relativeRejected=true,shortcut=true,discovery=Folders.Discover()});
            return 0;
        }catch(Exception ex){File.WriteAllText(Path.Combine(output,"error.txt"),ex.ToString());return 1;}
        finally{Registry.CurrentUser.DeleteSubKeyTree(key,false);}
    }
}
