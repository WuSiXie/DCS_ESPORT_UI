#pragma once
#include "websocket.hpp"
#include <type_traits>

template<class Stream>
class HttpSession : public std::enable_shared_from_this<HttpSession<Stream>> {
    Stream stream_;
    beast::flat_buffer buffer_;
    http::request_parser<http::string_body> parser_;
    http::response<http::string_body> response_;
    App& app_;
    static constexpr bool secure=!std::is_same_v<Stream,beast::tcp_stream>;
    auto self(){return this->shared_from_this();}
    void respond(http::status status,j::value payload) {
        response_.result(status);response_.version(11);response_.keep_alive(false);
        response_.set(http::field::content_type,"application/json; charset=utf-8");
        response_.set(http::field::cache_control,"no-store");
        response_.set(http::field::x_content_type_options,"nosniff");
        response_.body()=j::serialize(payload);response_.prepare_payload();
        beast::get_lowest_layer(stream_).expires_after(std::chrono::seconds(5));
        http::async_write(stream_,response_,[s=self()](auto,std::size_t){
            if constexpr(secure) {
                s->stream_.async_shutdown([s](auto){boost::system::error_code ignored;beast::get_lowest_layer(s->stream_).socket().close(ignored);});
            } else {boost::system::error_code ignored;s->stream_.socket().shutdown(tcp::socket::shutdown_send,ignored);}
        });
    }
    void login() {
        auto value=j::parse(parser_.get().body());auto& p=obj(value);
        auto name=str(field(p,"username"),64),password=str(field(p,"password"),1024);
        // Do not retain plaintext in the HTTP parser during the worker operation.
        OPENSSL_cleanse(parser_.get().body().data(),parser_.get().body().size());parser_.get().body().clear();
        auto job=app_.auth.begin(name,beast::get_lowest_layer(stream_).socket().remote_endpoint().address().to_string());
        if(!job){OPENSSL_cleanse(password.data(),password.size());respond(http::status::too_many_requests,{{"error","login_limited"}});return;}
        auto executor=stream_.get_executor();
        net::post(app_.passwordWorkers,[s=self(),job=*job,password=std::move(password),executor]() mutable {
            bool passed=false;try{passed=Auth::verify(job,password);}catch(...){}
            net::post(executor,[s,job,passed]{
                auto token=s->app_.auth.finish(job,passed);
                if(!token){s->respond(http::status::unauthorized,{{"error","invalid_credentials"}});return;}
                auto user=s->app_.auth.user(*token);
                s->respond(http::status::ok,{{"accessToken",*token},{"expiresIn",28800},{"user",user->publicInfo()},{"serverEpoch",s->app_.epoch}});
            });
        });
    }
    void route() {
        auto& r=parser_.get();std::string target(r.target());
        auto origin=r[http::field::origin];
        if(!origin.empty() && origin!=std::string(secure?"https://":"http://")+std::string(r[http::field::host])) {
            respond(http::status::forbidden,{{"error","origin_rejected"}});return;
        }
        if(r.method()==http::verb::get && target=="/healthz") {respond(http::status::ok,{{"status","ok"},{"version","0.4.1"}});return;}
        if(r.method()==http::verb::post && target=="/api/v1/auth/login"){login();return;}
        const std::string wsPrefix="/ws/v1/telemetry?ticket=";
        if(websocket::is_upgrade(r) && target.starts_with(wsPrefix)) {
            if(app_.webConnections>=32){respond(http::status::service_unavailable,{{"error","subscriber_capacity"}});return;}
            auto session=app_.auth.consume(target.substr(wsPrefix.size()));
            if(!session){respond(http::status::unauthorized,{{"error","invalid_ticket"}});return;}
            std::make_shared<WebSocketSession<Stream>>(std::move(stream_),app_,*session)->start(parser_.release());return;
        }
        std::string authorization(r[http::field::authorization]),token;
        if(authorization.starts_with("Bearer "))token=authorization.substr(7);
        auto user=app_.auth.user(token);
        bool diagnostic=!token.empty() && token==app_.apiToken && beast::get_lowest_layer(stream_).socket().remote_endpoint().address().is_loopback();
        if(!user && !diagnostic){respond(http::status::unauthorized,{{"error","unauthorized"}});return;}
        if(target.starts_with("/api/v1/auth/")) {
            if(!user){respond(http::status::forbidden,{{"error","user_session_required"}});return;}
            if(target=="/api/v1/auth/me" && r.method()==http::verb::get){respond(http::status::ok,user->publicInfo());return;}
            if(target=="/api/v1/auth/logout" && r.method()==http::verb::post){app_.auth.logout(token);respond(http::status::ok,{{"loggedOut",true}});return;}
            if(target=="/api/v1/auth/ws-ticket" && r.method()==http::verb::post){respond(http::status::ok,{{"ticket",app_.auth.ticket(token)},{"expiresIn",30}});return;}
            respond(http::status::method_not_allowed,{{"error","method_not_allowed"}});return;
        }
        if(r.method()!=http::verb::get){respond(http::status::method_not_allowed,{{"error","get_only"}});return;}
        if(target=="/api/v1/status") {
            if(!diagnostic && user->role!="admin"){respond(http::status::forbidden,{{"error","admin_required"}});return;}
            respond(http::status::ok,{{"serverEpoch",app_.epoch},{"ackMode","memory"},{"connections",app_.connections},{"webSubscribers",app_.webConnections},
                {"frames",app_.frames},{"protocolErrors",app_.errors},{"eventBytes",app_.store.bytes()}});return;
        }
        if(target=="/api/v1/sources"){respond(http::status::ok,diagnostic?app_.store.summaries():app_.sources(*user));return;}
        const std::string prefix="/api/v1/sources/";
        if(target.starts_with(prefix)) {
            auto slash=target.find('/',prefix.size());
            if(slash!=std::string::npos) {
                auto s=app_.store.byId(target.substr(prefix.size(),slash-prefix.size()));
                if(s && (diagnostic || user->allows(s->identity))) {
                    auto suffix=target.substr(slash);
                    if(suffix=="/snapshot"){respond(http::status::ok,{{"source",s->identity},{"state",s->snapshot}});return;}
                    if(suffix.starts_with("/events?afterSeq=")) {
                        auto numberText=suffix.substr(17);std::size_t used=0;
                        need(!numberText.empty() && numberText.find_first_not_of("0123456789")==std::string::npos,"invalid_cursor");
                        auto after=std::stoull(numberText,&used);need(used==numberText.size() && after<=MaxSeq,"invalid_cursor");
                        auto first=s->events.empty()?s->through+1:s->events.front().seq;
                        if(after>s->through || after+1<first){respond(http::status::conflict,{{"error","resync_required"},{"historyStart",first},{"gaps",s->gaps}});return;}
                        j::array events;std::size_t bytes=0;
                        for(auto& e:s->events)if(e.seq>after) {
                            if(events.size()>=128 || bytes+e.bytes>MaxFrame-8192)break;
                            bytes+=e.bytes;events.push_back(e.value);
                        }
                        respond(http::status::ok,{{"events",events},{"receivedThrough",s->through},{"gaps",s->gaps}});return;
                    }
                }
            }
        }
        respond(http::status::not_found,{{"error","not_found"}});
    }
    void read() {
        parser_.body_limit(8192);parser_.header_limit(8192);
        beast::get_lowest_layer(stream_).expires_after(std::chrono::seconds(5));
        http::async_read(stream_,buffer_,parser_,[s=self()](auto ec,std::size_t){
            if(ec)return;
            try{s->route();}catch(const std::exception&){s->respond(http::status::bad_request,{{"error","invalid_request"}});}
        });
    }
public:
    HttpSession(Stream stream,App& app):stream_(std::move(stream)),app_(app){++app_.connections;++app_.httpConnections;}
    ~HttpSession(){--app_.connections;--app_.httpConnections;}
    void start() {
        if constexpr(secure) {
            beast::get_lowest_layer(stream_).expires_after(std::chrono::seconds(5));
            stream_.async_handshake(net::ssl::stream_base::server,[s=self()](auto ec){if(!ec)s->read();});
        } else read();
    }
};
