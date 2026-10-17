#pragma once
#include "app.hpp"

template<class Stream>
class WebSocketSession : public std::enable_shared_from_this<WebSocketSession<Stream>> {
    websocket::stream<Stream> ws_;
    beast::flat_buffer buffer_;
    net::steady_timer timer_;
    App& app_;
    std::string token_;
    struct Subscription {std::uint64_t cursor=0,snapshotCount=0,baselineThrough=0;bool initial=true,historical=true;};
    std::map<std::string,Subscription> subscriptions_;
    std::deque<std::string> outgoing_;
    std::size_t bytes_=0;
    Clock::time_point statusSent_{};
    bool closed_=false;
    auto self(){return this->shared_from_this();}
    void close() {
        if(closed_)return;
        closed_=true;timer_.cancel();
        boost::system::error_code ignored;beast::get_lowest_layer(ws_).socket().close(ignored);
        // Keep queued buffers alive until the outstanding write handler completes.
    }
    bool send(j::object value) {
        if(closed_)return false;
        value["serverEpoch"]=app_.epoch;
        auto text=j::serialize(value);
        if(bytes_+text.size()>16*1024*1024){close();return false;}
        bytes_+=text.size();outgoing_.push_back(std::move(text));
        if(outgoing_.size()==1)write();
        return true;
    }
    void write() {
        ws_.text(true);ws_.async_write(net::buffer(outgoing_.front()),[s=self()](auto ec,std::size_t){
            if(ec){s->close();return;}
            s->bytes_-=s->outgoing_.front().size();s->outgoing_.pop_front();
            if(!s->closed_ && !s->outgoing_.empty())s->write();
        });
    }
    void read() {
        ws_.async_read(buffer_,[s=self()](auto ec,std::size_t){
            if(ec){s->close();return;}
            try {
                need(s->ws_.got_text(),"text_required");auto parsed=j::parse(beast::buffers_to_string(s->buffer_.data()));
                s->buffer_.consume(s->buffer_.size());s->handle(obj(parsed));
            } catch(const std::exception&) {s->send({{"type","error"},{"error","invalid_message"}});s->close();return;}
            if(!s->closed_)s->read();
        });
    }
    void handle(const j::object& message) {
        auto user=app_.auth.user(token_);if(!user){close();return;}
        auto type=str(field(message,"type"));
        if(type=="ping"){send({{"type","pong"}});return;}
        auto id=str(field(message,"sourceId"));
        if(type=="unsubscribe"){subscriptions_.erase(id);return;}
        need(type=="subscribe","unknown_message");
        auto source=app_.store.byId(id);
        if(!source || !user->allows(source->identity)){send({{"type","error"},{"error","source_unavailable"},{"sourceId",id}});return;}
        if(!subscriptions_.contains(id) && subscriptions_.size()>=16){send({{"type","error"},{"error","subscription_limit"}});return;}
        Subscription sub;sub.baselineThrough=source->through;
        auto after=message.if_contains("afterSeq"),epoch=message.if_contains("serverEpoch");
        if(after && epoch && epoch->is_string() && epoch->as_string()==app_.epoch) {
            sub.cursor=seq(*after);sub.historical=false;
            auto first=source->events.empty()?source->through+1:source->events.front().seq;
            if(sub.cursor>source->through || sub.cursor+1<first) {
                send({{"type","resync_required"},{"sourceId",id},{"reason","history_unavailable"},{"historyStart",first}});sub.historical=true;
            }
        } else if(after)send({{"type","resync_required"},{"sourceId",id},{"reason","server_epoch_changed"}});
        if(sub.historical)sub.cursor=source->events.empty()?source->through:source->events[source->events.size()>128?source->events.size()-128:0].seq-1;
        subscriptions_[id]=sub;
        send({{"type","subscribed"},{"sourceId",id},{"afterSeq",sub.cursor},{"historical",sub.historical}});
    }
    void pump() {
        if(closed_)return;
        auto user=app_.auth.user(token_);if(!user){close();return;}
        auto now=Clock::now();
        if(now-statusSent_>=std::chrono::seconds(1)) {
            statusSent_=now;if(!send({{"type","sources"},{"sources",app_.sources(*user)}}))return;
        }
        for(auto it=subscriptions_.begin();it!=subscriptions_.end();) {
            const auto id=it->first;auto& sub=it->second;auto source=app_.store.byId(id);
            if(!source || !user->allows(source->identity)) {
                send({{"type","source_removed"},{"sourceId",id}});it=subscriptions_.erase(it);continue;
            }
            if(sub.initial || source->snapshotCount!=sub.snapshotCount) {
                sub.initial=false;sub.snapshotCount=source->snapshotCount;
                if(!send({{"type","snapshot"},{"sourceId",id},{"source",source->identity},{"state",source->snapshot}}))return;
            }
            auto first=source->events.empty()?source->through+1:source->events.front().seq;
            if(sub.cursor+1<first) {
                if(!send({{"type","resync_required"},{"sourceId",id},{"reason","history_evicted"},{"historyStart",first}}))return;
                sub.cursor=first-1;sub.historical=true;sub.baselineThrough=source->through;
            }
            if(sub.cursor<source->through || sub.historical) {
                j::array events;std::size_t bytes=0;std::uint64_t through=sub.cursor;
                bool more=false;
                for(const auto& e:source->events)if(e.seq>sub.cursor) {
                    if(events.size()>=128 || bytes+e.bytes>MaxFrame-8192){more=true;break;}
                    // A baseline batch must not suppress live events arriving during replay.
                    if(sub.historical && e.seq>sub.baselineThrough){through=sub.baselineThrough;more=true;break;}
                    bytes+=e.bytes;events.push_back(e.value);through=e.seq;
                }
                if(!more)through=source->through;
                if(sub.historical)through=std::min(through,sub.baselineThrough);
                if(!send({{"type","events"},{"sourceId",id},{"events",events},{"throughSeq",through},
                    {"receivedThrough",source->through},{"gaps",source->gaps},{"historical",sub.historical}}))return;
                sub.cursor=through;if(sub.historical && through>=sub.baselineThrough)sub.historical=false;
            }
            ++it;
        }
        timer_.expires_after(std::chrono::milliseconds(100));timer_.async_wait([s=self()](auto ec){if(!ec)s->pump();});
    }
public:
    WebSocketSession(Stream stream,App& app,std::string token):ws_(std::move(stream)),timer_(ws_.get_executor()),app_(app),token_(std::move(token)){++app_.connections;++app_.webConnections;++app_.httpConnections;}
    ~WebSocketSession(){--app_.connections;--app_.webConnections;--app_.httpConnections;}
    void start(http::request<http::string_body> request) {
        beast::get_lowest_layer(ws_).expires_never();ws_.read_message_max(32768);
        auto timeout=websocket::stream_base::timeout::suggested(beast::role_type::server);
        timeout.idle_timeout=std::chrono::seconds(15);timeout.keep_alive_pings=true;ws_.set_option(timeout);
        ws_.async_accept(request,[s=self()](auto ec){
            if(ec){s->close();return;}
            auto user=s->app_.auth.user(s->token_);if(!user){s->close();return;}
            s->send({{"type","welcome"},{"protocolVersion",1},{"user",user->publicInfo()}});s->read();s->pump();
        });
    }
};
