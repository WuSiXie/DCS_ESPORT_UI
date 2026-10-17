#pragma once
#include "store.hpp"
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <filesystem>
#include <fstream>
#include <optional>
#include <set>

namespace esport {
inline std::string secureToken(std::size_t bytes=32) {
    std::vector<unsigned char> data(bytes);need(RAND_bytes(data.data(),int(bytes))==1,"random_failed");
    constexpr char hex[]="0123456789abcdef";std::string out;out.reserve(bytes*2);
    for(auto b:data){out+=hex[b>>4];out+=hex[b&15];}return out;
}
inline std::vector<unsigned char> unhex(const std::string& text) {
    need(text.size()%2==0,"invalid_hex");std::vector<unsigned char> bytes;
    auto digit=[](char c)->unsigned {if(c>='0' && c<='9')return c-'0';if(c>='a' && c<='f')return c-'a'+10;throw std::runtime_error("invalid_hex");};
    for(std::size_t i=0;i<text.size();i+=2)bytes.push_back(static_cast<unsigned char>((digit(text[i])<<4)|digit(text[i+1])));
    return bytes;
}
struct User {
    std::string name,role,salt,hash,fingerprint;
    std::set<std::string> instances;
    int iterations=600000;
    bool enabled=true;
    bool allows(const j::object& identity) const {return instances.contains("*") || instances.contains(str(field(identity,"instanceId")));}
    j::object publicInfo() const {j::array scopes;for(auto& s:instances)scopes.push_back(j::value(s));return {{"username",name},{"role",role},{"instances",scopes}};}
};
struct Session {User user;Clock::time_point expires;};
struct LoginJob {User user;bool exists=false;};
class Auth {
    std::string path_,fileContents_;
    std::map<std::string,User> users_;
    std::map<std::string,Session> sessions_;
    struct Ticket {std::string session;Clock::time_point expires;};
    std::map<std::string,Ticket> tickets_;
    struct Rate {Clock::time_point began;unsigned count=0;};
    std::map<std::string,Rate> rates_;
    Clock::time_point checked_{};
    bool available_=true;
    unsigned inFlight_=0;
    void prune() {
        const auto now=Clock::now();
        std::erase_if(sessions_,[&](const auto& p){return now>=p.second.expires;});
        std::erase_if(tickets_,[&](const auto& p){return now>=p.second.expires || !sessions_.contains(p.second.session);});
        std::erase_if(rates_,[&](const auto& p){return now-p.second.began>=std::chrono::minutes(1);});
    }
public:
    void configure(std::string path) {path_=std::move(path);reload(true);}
    void reload(bool required=false) {
        if(path_.empty())return;
        auto now=Clock::now();if(!required && now-checked_<std::chrono::seconds(1))return;checked_=now;
        try {
            std::ifstream file(path_,std::ios::binary);need(bool(file),"users_file_unavailable");
            need(std::filesystem::file_size(path_)<=1024*1024,"users_file_too_large");
            std::string contents((std::istreambuf_iterator<char>(file)),{});
            if(available_ && contents==fileContents_)return;
            auto root=j::parse(contents);auto& document=obj(root);
            need(seq(field(document,"version"))==1,"users_version");
            const auto& list=field(document,"users");need(list.is_array() && list.as_array().size()<=256,"users_limit");
            std::map<std::string,User> next;
            for(const auto& item:list.as_array()) {
                const auto& row=obj(item);User u;u.name=str(field(row,"username"),64);
                need(u.name.size()>=2 && u.name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")==std::string::npos,"invalid_username");
                u.role=str(field(row,"role"));need(u.role=="admin" || u.role=="director" || u.role=="viewer","invalid_role");
                const auto& enabled=field(row,"enabled");need(enabled.is_bool(),"enabled_required");u.enabled=enabled.as_bool();
                const auto& pass=obj(field(row,"password"));need(str(field(pass,"algorithm"))=="pbkdf2-sha256","password_algorithm");
                auto iterations=seq(field(pass,"iterations"));need(iterations>=600000 && iterations<=2000000,"password_work_factor");u.iterations=int(iterations);
                u.salt=str(field(pass,"salt"),64);u.hash=str(field(pass,"hash"),64);
                need(unhex(u.salt).size()>=16 && unhex(u.hash).size()==32,"password_hash_length");
                const auto& scopes=field(row,"instances");need(scopes.is_array() && scopes.as_array().size()<=64,"invalid_scopes");
                for(const auto& s:scopes.as_array())u.instances.insert(str(s));
                u.fingerprint=j::serialize(row);need(next.emplace(u.name,u).second,"duplicate_username");
            }
            users_=std::move(next);fileContents_=std::move(contents);available_=true;
            std::erase_if(sessions_,[&](const auto& pair){auto it=users_.find(pair.second.user.name);return it==users_.end() || !it->second.enabled || it->second.fingerprint!=pair.second.user.fingerprint;});
            prune();
        } catch(...) {available_=false;sessions_.clear();tickets_.clear();if(required)throw;}
    }
    // All maps and counters belong to the IO thread. Only verify() runs in a worker.
    std::optional<LoginJob> begin(const std::string& name,const std::string& peer) {
        reload();prune();if(!available_ || inFlight_>=8 || sessions_.size()>=1024)return std::nullopt;
        for(auto key:{"ip:"+peer,"user:"+name}) {
            if(!rates_.contains(key) && rates_.size()>=512)return std::nullopt;
            auto [it,inserted]=rates_.try_emplace(key,Rate{Clock::now(),0});(void)inserted;
            if(++it->second.count>5)return std::nullopt;
        }
        ++inFlight_;LoginJob job;auto it=users_.find(name);
        if(it!=users_.end()){job.user=it->second;job.exists=it->second.enabled;}
        else {job.user.name=name;job.user.salt=std::string(32,'0');job.user.hash=std::string(64,'0');}
        return job;
    }
    static bool verify(const LoginJob& job,std::string& password) {
        auto salt=unhex(job.user.salt),expected=unhex(job.user.hash);unsigned char derived[32]{};
        bool success=PKCS5_PBKDF2_HMAC(password.data(),int(password.size()),salt.data(),int(salt.size()),job.user.iterations,EVP_sha256(),32,derived)==1;
        OPENSSL_cleanse(password.data(),password.size());password.clear();
        bool matches=success && CRYPTO_memcmp(expected.data(),derived,32)==0;OPENSSL_cleanse(derived,32);
        return matches && job.exists;
    }
    std::optional<std::string> finish(const LoginJob& job,bool passed) {
        if(inFlight_)--inFlight_;
        reload();auto it=users_.find(job.user.name);
        if(!available_ || !passed || it==users_.end() || !it->second.enabled || it->second.fingerprint!=job.user.fingerprint)return std::nullopt;
        auto token=secureToken();sessions_.emplace(token,Session{it->second,Clock::now()+std::chrono::hours(8)});return token;
    }
    std::optional<User> user(const std::string& token) {
        reload();prune();auto it=sessions_.find(token);if(it==sessions_.end())return std::nullopt;return it->second.user;
    }
    void logout(const std::string& token) {sessions_.erase(token);prune();}
    std::string ticket(const std::string& token) {
        need(bool(user(token)),"unauthorized");need(tickets_.size()<1024,"ticket_capacity");
        auto value=secureToken();tickets_.emplace(value,Ticket{token,Clock::now()+std::chrono::seconds(30)});return value;
    }
    std::optional<std::string> consume(const std::string& ticket) {
        reload();prune();auto it=tickets_.find(ticket);if(it==tickets_.end())return std::nullopt;
        auto token=it->second.session;tickets_.erase(it);if(!user(token))return std::nullopt;return token;
    }
};
}
