#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <wintrust.h>
#include <softpub.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <string>
#include <algorithm>
#include <functional>
#include <cstdio>
#include "prerequisite.hpp"
#include "BootstrapInfo.hpp"

namespace fs=std::filesystem;
struct Failure {std::wstring message; DWORD code=1;};
struct Handle {
    HANDLE value=INVALID_HANDLE_VALUE;
    explicit Handle(HANDLE h=INVALID_HANDLE_VALUE):value(h){}
    ~Handle(){if(value!=INVALID_HANDLE_VALUE&&value)CloseHandle(value);}
    Handle(const Handle&)=delete; Handle& operator=(const Handle&)=delete;
};
std::string utf8(const std::wstring& s) {
    int n=WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),nullptr,0,nullptr,nullptr);
    std::string out(n,'\0');WideCharToMultiByte(CP_UTF8,0,s.data(),int(s.size()),out.data(),n,nullptr,nullptr);return out;
}
std::string json(const std::wstring& s) {
    std::string out="\"";for(unsigned char ch:utf8(s)){if(ch=='"'||ch=='\\'){out+='\\';out+=char(ch);}else if(ch<32){char b[7];snprintf(b,sizeof(b),"\\u%04x",ch);out+=b;}else out+=char(ch);}return out+'"';
}
std::wstring quote(const std::wstring& s) {
    std::wstring out=L"\"";unsigned slash=0;
    for(auto ch:s){if(ch==L'\\'){++slash;continue;}if(ch==L'"'){out.append(slash*2+1,L'\\');out+=ch;}else{out.append(slash,L'\\');out+=ch;}slash=0;}
    out.append(slash*2,L'\\');return out+L'"';
}
DWORD releaseView(REGSAM view) {
    HKEY key=nullptr;
    auto status=RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full",0,KEY_QUERY_VALUE|view,&key);
    if(status==ERROR_FILE_NOT_FOUND||status==ERROR_PATH_NOT_FOUND)return 0;
    if(status!=ERROR_SUCCESS)throw Failure{L"无法读取 .NET Framework 注册表，未尝试安装。",DWORD(status)};
    DWORD release=0,size=sizeof(release),type=0;status=RegQueryValueExW(key,L"Release",nullptr,&type,reinterpret_cast<BYTE*>(&release),&size);RegCloseKey(key);
    if(status==ERROR_FILE_NOT_FOUND)return 0;
    if(status!=ERROR_SUCCESS||type!=REG_DWORD)throw Failure{L".NET Framework Release 注册表值无效，未尝试安装。",DWORD(status?status:ERROR_INVALID_DATA)};
    return release;
}
DWORD release(){return std::max(releaseView(KEY_WOW64_64KEY),releaseView(KEY_WOW64_32KEY));}
void safePath(const fs::path& p) {
    auto current=fs::absolute(p);
    while(!current.empty()) {
        DWORD a=GetFileAttributesW(current.c_str());
        if(a!=INVALID_FILE_ATTRIBUTES&&(a&FILE_ATTRIBUTE_REPARSE_POINT))throw Failure{L"缓存目录包含链接，请选择实际目录。"};
        auto parent=current.parent_path();if(parent==current)break;current=parent;
    }
}
void report(const fs::path& path,const std::string& data) {
    if(path.empty())return;
    safePath(path);if(path.has_parent_path())fs::create_directories(path.parent_path());
    std::ofstream f(path,std::ios::binary|std::ios::trunc);f<<data;f.close();if(!f)throw Failure{L"无法写入安装检测报告。"};
}
struct Hash {
    BCRYPT_ALG_HANDLE alg=nullptr;BCRYPT_HASH_HANDLE handle=nullptr;std::vector<BYTE> obj;
    Hash(){DWORD bytes=0,n=0;if(BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0||BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,reinterpret_cast<BYTE*>(&bytes),sizeof(bytes),&n,0)<0)throw Failure{L"无法初始化文件校验。"};obj.resize(bytes);if(BCryptCreateHash(alg,&handle,obj.data(),bytes,nullptr,0,0)<0)throw Failure{L"无法初始化 SHA-256。"};}
    ~Hash(){if(handle)BCryptDestroyHash(handle);if(alg)BCryptCloseAlgorithmProvider(alg,0);}
    void add(const BYTE* p,ULONG size){if(BCryptHashData(handle,const_cast<BYTE*>(p),size,0)<0)throw Failure{L"文件校验失败。"};}
    std::string finish(){BYTE digest[32];if(BCryptFinishHash(handle,digest,32,0)<0)throw Failure{L"文件校验失败。"};std::string out;for(auto b:digest){out+="0123456789abcdef"[b>>4];out+="0123456789abcdef"[b&15];}return out;}
};
std::string fileHash(HANDLE file) {
    LARGE_INTEGER zero{};SetFilePointerEx(file,zero,nullptr,FILE_BEGIN);Hash hash;BYTE data[65536];DWORD got;
    while(true){if(!ReadFile(file,data,sizeof(data),&got,nullptr))throw Failure{L"无法读取缓存文件。"};if(!got)break;hash.add(data,got);}return hash.finish();
}
void extract(int id,const fs::path& path,const std::string& expected) {
    auto res=FindResourceW(nullptr,MAKEINTRESOURCEW(id),RT_RCDATA);if(!res)throw Failure{L"安装包资源缺失，请重新下载安装包。"};
    auto resource=LoadResource(nullptr,res);auto data=static_cast<const BYTE*>(LockResource(resource));DWORD size=SizeofResource(nullptr,res);
    Hash hash;hash.add(data,size);if(hash.finish()!=expected)throw Failure{L"内置安装资源损坏，已停止。"};
    safePath(path);fs::create_directories(path.parent_path());
    {Handle existing(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));if(existing.value!=INVALID_HANDLE_VALUE&&fileHash(existing.value)==expected)return;}
    Handle f(CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr));
    if(f.value==INVALID_HANDLE_VALUE)throw Failure{L"无法写入离线安装缓存。请关闭同一安装包的其他窗口后重试。"};
    DWORD written=0;if(!WriteFile(f.value,data,size,&written,nullptr)||written!=size||!FlushFileBuffers(f.value))throw Failure{L"离线安装资源写入失败，请检查磁盘空间。"};
}
bool trusted(const fs::path& path,HANDLE file) {
    WINTRUST_FILE_INFO info{};info.cbStruct=sizeof(info);info.pcwszFilePath=path.c_str();info.hFile=file;
    WINTRUST_DATA data{};data.cbStruct=sizeof(data);data.dwUIChoice=WTD_UI_NONE;data.fdwRevocationChecks=WTD_REVOKE_NONE;data.dwUnionChoice=WTD_CHOICE_FILE;data.pFile=&info;data.dwStateAction=WTD_STATEACTION_VERIFY;data.dwProvFlags=WTD_CACHE_ONLY_URL_RETRIEVAL;
    GUID action=WINTRUST_ACTION_GENERIC_VERIFY_V2;LONG result=WinVerifyTrust(nullptr,&action,&data);data.dwStateAction=WTD_STATEACTION_CLOSE;WinVerifyTrust(nullptr,&action,&data);return result==ERROR_SUCCESS;
}
DWORD wait(HANDLE process) {WaitForSingleObject(process,INFINITE);DWORD code=1;if(!GetExitCodeProcess(process,&code))throw Failure{L"无法读取子安装程序结果。"};return code;}
DWORD installFramework(const fs::path& cache) {
    const auto exe=cache/L"NDP48-x86-x64-AllOS-ENU.exe";extract(102,exe,bootstrap_info::dotnet_hash);
    // Hold a non-writable/non-deletable handle from hash/signature checks through elevation and exit.
    Handle lock(CreateFileW(exe.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    if(lock.value==INVALID_HANDLE_VALUE||fileHash(lock.value)!=bootstrap_info::dotnet_hash||!trusted(exe,lock.value))throw Failure{L"微软 .NET 离线安装包签名或哈希校验失败，未执行安装。"};
    std::wstring params=L"/passive /norestart /ChainingPackage DcsEsportUI /log "+quote((cache/L"dotnet48-install.log").wstring());
    SHELLEXECUTEINFOW se{};se.cbSize=sizeof(se);se.fMask=SEE_MASK_NOCLOSEPROCESS|SEE_MASK_FLAG_NO_UI;se.lpVerb=L"runas";se.lpFile=exe.c_str();se.lpParameters=params.c_str();se.lpDirectory=cache.c_str();se.nShow=SW_SHOWNORMAL;
    if(!ShellExecuteExW(&se)){auto code=GetLastError();if(code==ERROR_CANCELLED)return ERROR_CANCELLED;throw Failure{L"无法启动 .NET 离线安装程序。",code};}
    Handle process(se.hProcess);return wait(process.value);
}
DWORD launchManager(const fs::path& cache,const std::vector<std::wstring>& args) {
    const auto exe=cache/L"DcsEsportManager.exe";extract(101,exe,bootstrap_info::manager_hash);
    Handle lock(CreateFileW(exe.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
    if(lock.value==INVALID_HANDLE_VALUE||fileHash(lock.value)!=bootstrap_info::manager_hash)throw Failure{L"项目安装器校验失败。"};
    std::wstring cmd=quote(exe.wstring());for(const auto& arg:args)cmd+=L" "+quote(arg);
    STARTUPINFOW si{};si.cb=sizeof(si);PROCESS_INFORMATION pi{};
    if(!CreateProcessW(exe.c_str(),cmd.data(),nullptr,nullptr,FALSE,0,nullptr,nullptr,&si,&pi))throw Failure{L"无法启动项目安装器。",GetLastError()};
    Handle process(pi.hProcess),thread(pi.hThread);return wait(process.value);
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    fs::path output,cache;bool statusOnly=false,verifyOnly=false;std::vector<std::wstring> forwarded;
    try {
        int argc=0;LPWSTR* argv=CommandLineToArgvW(GetCommandLineW(),&argc);
        for(int i=1;i<argc;i++) {
            std::wstring a=argv[i];
            if(a==L"--prereq-status"){statusOnly=true;continue;}
            if(a==L"--verify-bundle"){verifyOnly=true;continue;}
            if(a==L"--bootstrap-cache"){if(i+1>=argc)throw Failure{L"缺少缓存目录参数。"};cache=argv[++i];continue;}
            if(a==L"--report"&&i+1<argc)output=argv[i+1];
            forwarded.push_back(a);
        }LocalFree(argv);
        DWORD before=release();
        if(statusOnly){report(output,"{\"ok\":true,\"release\":"+std::to_string(before)+",\"minimumRelease\":528040,\"sufficient\":"+(before>=528040?"true":"false")+",\"nativeBootstrap\":true}");return 0;}
        if(cache.empty()) {PWSTR local=nullptr;if(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&local)!=S_OK)throw Failure{L"无法识别当前用户应用数据目录。"};cache=fs::path(local)/L"DcsEsportUI"/L"SetupCache";CoTaskMemFree(local);}
        cache=fs::absolute(cache)/bootstrap_info::manager_hash.substr(0,24);safePath(cache);fs::create_directories(cache);
        if(verifyOnly) {
            const auto file=cache/L"NDP48-x86-x64-AllOS-ENU.exe";extract(102,file,bootstrap_info::dotnet_hash);
            Handle lock(CreateFileW(file.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
            if(lock.value==INVALID_HANDLE_VALUE||fileHash(lock.value)!=bootstrap_info::dotnet_hash||!trusted(file,lock.value))throw Failure{L"离线安装包校验失败。"};
            extract(101,cache/L"DcsEsportManager.exe",bootstrap_info::manager_hash);
            report(output,"{\"ok\":true,\"offlineSignatureValid\":true,\"dotnetSha256\":\""+bootstrap_info::dotnet_hash+"\",\"managerSha256\":\""+bootstrap_info::manager_hash+"\"}");return 0;
        }
        auto result=prerequisite::ensure(release,[&](){return installFramework(cache);});
        report(cache/L"bootstrap-status.json","{\"initialRelease\":"+std::to_string(before)+",\"installerInvoked\":"+(result.installed||result.code?"true":"false")+",\"exitCode\":"+std::to_string(result.code)+"}");
        if(result.state!=prerequisite::State::ready) {
            std::wstring msg;
            if(result.state==prerequisite::State::restart_required)msg=L".NET Framework 安装已完成，需要重启 Windows。请保存工作并自行重启，然后重新运行本安装包继续。安装器不会强制重启。";
            else if(result.state==prerequisite::State::cancelled)msg=L"已取消 .NET Framework 安装或管理员授权，项目尚未安装。需要时重新运行本安装包。";
            else if(result.code==5100)msg=L"当前 Windows 环境不满足 .NET Framework 4.8 安装要求，请先完成必要的系统更新。";
            else if(result.state==prerequisite::State::not_detected)msg=L".NET 安装程序已退出，但尚未检测到 4.8。请检查安装日志，必要时重启 Windows 后重试。";
            else msg=L".NET Framework 安装失败，返回码："+std::to_wstring(result.code)+L"。";
            msg+=L"\n日志目录："+cache.wstring();throw Failure{msg,result.code};
        }
        return int(launchManager(cache,forwarded));
    } catch(const Failure& f) {
        try{report(output,"{\"ok\":false,\"stage\":\"prerequisite\",\"exitCode\":"+std::to_string(f.code)+",\"error\":"+json(f.message)+"}");}catch(...){}
        if(output.empty())MessageBoxW(nullptr,f.message.c_str(),L"DCS 电竞 UI - 环境准备",MB_OK|(f.code==3010||f.code==1641?MB_ICONINFORMATION:MB_ICONERROR));
        return int(f.code?f.code:1);
    } catch(const std::exception&) {
        try{report(output,"{\"ok\":false,\"stage\":\"bootstrap\",\"error\":\"Cache or file operation failed\"}");}catch(...){}
        if(output.empty())MessageBoxW(nullptr,L"安装缓存读取或写入失败，请检查目录权限和磁盘空间。",L"DCS 电竞 UI",MB_OK|MB_ICONERROR);
        return 1;
    }
}
