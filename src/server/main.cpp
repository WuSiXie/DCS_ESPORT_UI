#include "web.hpp"
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <array>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>
#include <iomanip>
#include <ctime>

class Ingress : public std::enable_shared_from_this<Ingress> {
    tcp::socket socket_;
    net::steady_timer timer_;
    App& app_;
    std::array<unsigned char,4> header_{};
    std::string body_, id_, instance_;
    std::string peerAddress_;
    unsigned short peerPort_=0, localPort_=0;
    std::uint64_t ingressId_=0;
    bool authenticated_=false, closed_=false;
    std::deque<std::string> outgoing_;
    std::size_t outgoingBytes_=0;
    void reject(const char* stage, const std::string& reason) {
        ++app_.errors;
        const auto now=std::chrono::system_clock::now();
        const auto seconds=std::chrono::system_clock::to_time_t(now);
        const auto utc=*std::gmtime(&seconds);
        std::ostringstream timestamp, hex;
        timestamp<<std::put_time(&utc,"%Y-%m-%dT%H:%M:%SZ");
        std::uint32_t length=0;
        for(auto b:header_) { length=(length<<8)|b;hex<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(b); }
        // Never log bodies, credentials, or untrusted message fields.
        j::object entry{{"event","ingress_rejected"},{"timestampUtc",timestamp.str()},
            {"serverEpoch",app_.epoch},{"ingressId",ingressId_},{"peerAddress",peerAddress_},
            {"peerPort",peerPort_},{"localPort",localPort_},{"authenticated",authenticated_},
            {"connectionId",id_.empty()?j::value(nullptr):j::value(id_)},
            {"stage",stage},{"reason",reason.substr(0,256)},{"declaredLength",length},
            {"headerHex",hex.str()},{"protocolErrors",app_.errors}};
        if(authenticated_)entry["instanceId"]=instance_;
        std::cerr<<j::serialize(entry)<<std::endl;
        close();
    }
    void close() {
        if(closed_) return;
        closed_=true;
        if(authenticated_)app_.store.disconnected(instance_,id_);
        boost::system::error_code ignored; timer_.cancel(); socket_.close(ignored);
    }
    void timeout() {
        timer_.expires_after(std::chrono::seconds(15));
        timer_.async_wait([self=shared_from_this()](auto ec){if(!ec)self->close();});
    }
    j::object message(const char* type, j::value payload, const j::object* source=nullptr) {
        j::object m{{"transportVersion",1},{"type",type},{"connectionId",id_},{"serverEpoch",app_.epoch},
                    {"ackMode","memory"},{"payload",std::move(payload)}};
        if(source)m["source"]=*source;
        return m;
    }
    void send(j::object response) {
        auto text=j::serialize(response); need(text.size()<=MaxFrame,"response_too_large");
        std::string frame(4,'\0'); auto n=std::uint32_t(text.size());
        for(int i=0;i<4;++i) frame[i]=char(n>>(24-i*8));
        frame+=text;
        need(outgoingBytes_+frame.size()<=1024*1024,"slow_hook");
        outgoingBytes_+=frame.size(); outgoing_.push_back(std::move(frame));
        if(outgoing_.size()==1) write();
    }
    void write() {
        net::async_write(socket_,net::buffer(outgoing_.front()),[self=shared_from_this()](auto ec,std::size_t){
            if(ec){self->close();return;}
            self->outgoingBytes_-=self->outgoing_.front().size(); self->outgoing_.pop_front();
            if(!self->outgoing_.empty())self->write();
        });
    }
    void readHeader() {
        if(closed_)return;
        net::async_read(socket_,net::buffer(header_),[self=shared_from_this()](auto ec,std::size_t){
            if(ec){self->close();return;}
            std::uint32_t n=0; for(auto b:self->header_)n=(n<<8)|b;
            if(!n || n>MaxFrame){self->reject("header",!n?"empty_frame":"frame_too_large");return;}
            self->body_.resize(n); self->readBody();
        });
    }
    void readBody() {
        net::async_read(socket_,net::buffer(body_),[self=shared_from_this()](auto ec,std::size_t){
            if(ec){self->close();return;}
            const char* stage="json";
            try {
                boost::json::parse_options options; options.max_depth=64;
                auto value=j::parse(self->body_,{},options); stage="protocol";
                self->handle(obj(value)); ++self->app_.frames;
            } catch(const std::exception& e) {
                // Protocol errors terminate the connection: no ambiguous partial acceptance.
                self->reject(stage,e.what());return;
            }
            self->timeout();self->readHeader();
        });
    }
    void handle(const j::object& m) {
        need(seq(field(m,"transportVersion"))==1,"transport_version");
        auto type=str(field(m,"type")); const auto& p=obj(field(m,"payload"));
        if(!authenticated_) {
            need(type=="hello","hello_required");
            need(str(field(p,"token"))==app_.token,"authentication_failed");
            instance_=str(field(p,"instanceId")); need(instance_==app_.instance,"instance_not_allowed");
            need(str(field(p,"ackMode"))=="memory","ack_mode_required");
            id_=std::to_string(++app_.connectionNumber); app_.owners[instance_]=id_; authenticated_=true;
            app_.store.connected(instance_,id_);
            send(message("welcome",{{"maxFrameBytes",MaxFrame}})); return;
        }
        need(str(field(m,"connectionId"))==id_ && app_.owners[instance_]==id_,"stale_connection");
        if(type=="ping"){send(message("pong",{}));return;}
        const auto& identity=obj(field(m,"source"));
        if(type=="source_open") {
            auto confirmed=seq(field(p,"confirmedSeq")); need(confirmed<=seq(field(p,"readThrough")),"invalid_source_cursor");
            auto& s=app_.store.open(identity,instance_,confirmed);
            app_.store.touch(s,id_);
            send(message("source_ready",{{"ackEventSeq",s.through},{"historyIncomplete",s.historyIncomplete}},&identity));return;
        }
        auto& s=app_.store.get(identity,instance_);
        app_.store.touch(s,id_);
        if(type=="events") {
            app_.store.events(s,p);send(message("ack",{{"ackEventSeq",s.through}},&identity));
        } else if(type=="snapshot") app_.store.snapshot(s,p);
        else if(type=="status") {
            need(j::serialize(p).size()<=32768,"status_too_large");app_.store.status(s,p);

        }
        else if(type=="session_end") {
            app_.store.end(s,p);send(message("session_end_received",p,&identity));
        } else need(false,"unknown_message");
    }
public:
    Ingress(tcp::socket socket,App& app):socket_(std::move(socket)),timer_(socket_.get_executor()),app_(app){
        ++app_.connections;++app_.ingressConnections;ingressId_=++app_.ingressNumber;
        auto peer=socket_.remote_endpoint();peerAddress_=peer.address().to_string();peerPort_=peer.port();
        localPort_=socket_.local_endpoint().port();
    }
    ~Ingress(){--app_.connections;--app_.ingressConnections;}
    void start(){timeout();readHeader();}
};

class Listener {
    tcp::acceptor acceptor_; App& app_; bool http_; net::ssl::context* tls_;
public:
    Listener(net::io_context& io,App& app,unsigned short port,bool isHttp,const std::string& bind="127.0.0.1",net::ssl::context* tls=nullptr):
        acceptor_(io,tcp::endpoint(net::ip::make_address(bind),port)),app_(app),http_(isHttp),tls_(tls){accept();}
    void accept() {
        acceptor_.async_accept([this](auto ec,tcp::socket socket){
            if(!ec && (http_?app_.httpConnections<64:app_.ingressConnections<8)) {
                if(tls_)std::make_shared<HttpSession<beast::ssl_stream<beast::tcp_stream>>>(beast::ssl_stream<beast::tcp_stream>(std::move(socket),*tls_),app_)->start();
                else if(http_)std::make_shared<HttpSession<beast::tcp_stream>>(beast::tcp_stream(std::move(socket)),app_)->start();
                else std::make_shared<Ingress>(std::move(socket),app_)->start();
            }
            if(acceptor_.is_open())accept();
        });
    }
};
int main(int argc,char** argv) {
    try {
        App app;net::io_context io(1); unsigned short port=9081,httpPort=9080,tlsPort=0;
        std::string users,certificate,key,tlsBind="127.0.0.1";
        const char* token=std::getenv("DCS_ESPORT_HOOK_TOKEN"); const char* api=std::getenv("DCS_ESPORT_API_TOKEN");
        need(token && std::string(token).size()>=32,"DCS_ESPORT_HOOK_TOKEN must contain at least 32 characters");
        need(api && std::string(api).size()>=32,"DCS_ESPORT_API_TOKEN must contain at least 32 characters");
        app.token=token;app.apiToken=api;
        for(int i=1;i<argc;i+=2) {
            need(i+1<argc,"missing_argument"); std::string arg=argv[i];
            if(arg=="--instance")app.instance=argv[i+1];
            else if(arg=="--users")users=argv[i+1];
            else if(arg=="--tls-cert")certificate=argv[i+1];
            else if(arg=="--tls-key")key=argv[i+1];
            else if(arg=="--tls-bind")tlsBind=argv[i+1];
            else { auto n=std::stoi(argv[i+1]);need(n>0 && n<65536,"invalid_port");
                if(arg=="--port")port=static_cast<unsigned short>(n);
                else if(arg=="--http-port")httpPort=static_cast<unsigned short>(n);
                else if(arg=="--tls-port")tlsPort=static_cast<unsigned short>(n);else need(false,"unknown_argument"); }
        }
        app.auth.configure(users);
        Listener ingress(io,app,port,false),httpListener(io,app,httpPort,true);
        net::ssl::context tls(net::ssl::context::tls_server);
        std::unique_ptr<Listener> tlsListener;
        if(tlsPort) {
            need(!certificate.empty() && !key.empty(),"tls_certificate_and_key_required");
            SSL_CTX_set_min_proto_version(tls.native_handle(),TLS1_2_VERSION);
            tls.use_certificate_chain_file(certificate);tls.use_private_key_file(key,net::ssl::context::pem);
            need(SSL_CTX_check_private_key(tls.native_handle())==1,"tls_key_mismatch");
            tlsListener=std::make_unique<Listener>(io,app,tlsPort,true,tlsBind,&tls);
        }
        net::signal_set signals(io,SIGINT,SIGTERM);signals.async_wait([&](auto,int){io.stop();});
        std::cout<<"DCS Esport server 0.4.1; memory ACK; TCP 127.0.0.1:"<<port<<" HTTP 127.0.0.1:"<<httpPort<<std::endl;
        io.run();app.passwordWorkers.join();return 0;
    } catch(const std::exception& e){std::cerr<<e.what()<<std::endl;return 1;}
}
