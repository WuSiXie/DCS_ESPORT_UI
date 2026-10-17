#pragma once
#include <boost/json.hpp>
#include <algorithm>
#include <chrono>
#include <deque>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace esport {
namespace j = boost::json;
using Clock = std::chrono::steady_clock;
inline constexpr std::size_t MaxFrame = 512 * 1024;
inline constexpr std::uint64_t MaxSeq = 9007199254740991ULL;
inline void need(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
inline const j::object& obj(const j::value& v) { need(v.is_object(), "object_required"); return v.as_object(); }
inline const j::value& field(const j::object& o, const char* key) {
    auto p = o.if_contains(key); need(p != nullptr, "missing_field"); return *p;
}
inline std::string str(const j::value& v, std::size_t max = 256) {
    need(v.is_string() && !v.as_string().empty() && v.as_string().size() <= max, "invalid_string");
    return std::string(v.as_string());
}
inline std::uint64_t seq(const j::value& v) {
    need(v.is_int64() || v.is_uint64(), "integer_required");
    if (v.is_int64()) need(v.as_int64() >= 0, "negative_sequence");
    auto n = v.is_uint64() ? v.as_uint64() : std::uint64_t(v.as_int64());
    need(n <= MaxSeq, "sequence_limit"); return n;
}
inline double number(const j::value& v) {
    need(v.is_number(), "number_required"); return v.to_number<double>();
}
inline std::string sourceKey(const j::object& source, const std::string& instance) {
    need(str(field(source, "instanceId")) == instance, "wrong_instance");
    // Length prefixes avoid delimiter collisions in arbitrary opaque identifiers.
    std::string result;
    for (auto k : {"instanceId", "missionSessionId", "collectorEpoch"}) {
        auto s = str(field(source,k)); result += std::to_string(s.size()) + ":" + s;
    }
    return result;
}
struct Event { std::uint64_t seq; j::value value; std::size_t bytes; };
struct Source {
    std::string id;
    j::object identity;
    std::uint64_t through=0, accepted=0, duplicates=0, snapshotCount=0;
    std::size_t bytes=0;
    std::deque<Event> events;
    j::array gaps;
    bool historyIncomplete=false;
    j::value snapshot=nullptr, end=nullptr, status=nullptr;
    j::object assembly;
    std::size_t assemblyBytes=0, nextPage=0;
    Clock::time_point assemblyStarted{};
    Clock::time_point receivedAt{}, statusAt{}, snapshotAt{};
    std::string connectionId;
    std::uint64_t evictedEvents=0;
    bool archived=false;
};
class Store {
    std::map<std::string,Source> sources_;
    std::map<std::string,Source> archives_;
    std::uint64_t nextId_=0;
    std::size_t bytes_=0;
    std::map<std::string,std::string> connections_;
    void trim(Source& s) {
        while (!s.events.empty() && (s.events.size()>10000 || s.bytes>16*1024*1024 || bytes_>64*1024*1024)) {
            s.bytes-=s.events.front().bytes; bytes_-=s.events.front().bytes; s.events.pop_front();++s.evictedEvents;
        }
    }
    void gap(Source& s, j::object value) {
        s.historyIncomplete=true;
        if (s.gaps.size() == 1024) s.gaps.erase(s.gaps.begin());
        s.gaps.push_back(std::move(value));
    }
    void makeRoom() {
        if(sources_.size()<64)return;
        auto oldest=sources_.end();
        for(auto it=sources_.begin();it!=sources_.end();++it) {
            const auto& s=it->second;if(!s.end.is_object())continue;
            const auto& end=s.end.as_object();auto final=end.if_contains("latestEventSeq"),confirmed=end.if_contains("confirmedSeq");
            bool complete=final && !final->is_null() && seq(*final)==s.through;
            auto closed=end.if_contains("captureClosed");auto read=end.if_contains("readThrough");
            bool abandoned=closed && closed->is_bool() && closed->as_bool() && read && seq(*read)==s.through;
            if((!complete && !abandoned) || !confirmed || seq(*confirmed)!=s.through)continue;
            if(oldest==sources_.end() || s.receivedAt<oldest->second.receivedAt)oldest=it;
        }
        need(oldest!=sources_.end(),"source_capacity_unfinished");
        auto& s=oldest->second;bytes_-=s.bytes;s.bytes=0;s.evictedEvents+=s.events.size();s.events.clear();
        s.snapshot=nullptr;s.assembly.clear();s.assemblyBytes=0;s.archived=true;
        archives_.emplace(oldest->first,std::move(s));sources_.erase(oldest);
        // Compact receipts let an old Hook reopen without resurrecting evicted
        // event bodies or evicting the currently running mission in a loop.
        if(archives_.size()>128) {
            auto first=std::min_element(archives_.begin(),archives_.end(),[](const auto& a,const auto& b){
                return std::stoull(a.second.id)<std::stoull(b.second.id);
            });archives_.erase(first);
        }
    }
public:
    void connected(const std::string& instance,const std::string& connection) { connections_[instance]=connection; }
    void disconnected(const std::string& instance,const std::string& connection) {
        auto it=connections_.find(instance);if(it!=connections_.end() && it->second==connection)connections_.erase(it);
    }
    void touch(Source& s,const std::string& connection) { s.connectionId=connection;s.receivedAt=Clock::now(); }
    void status(Source& s,const j::object& payload) {s.status=payload;s.statusAt=Clock::now();}
    Source& open(const j::object& identity, const std::string& instance, std::uint64_t confirmed) {
        auto key=sourceKey(identity,instance);
        auto it=sources_.find(key);
        if (it!=sources_.end()) { need(confirmed<=it->second.through,"ack_ahead_of_server"); return it->second; }
        auto archived=archives_.find(key);
        if(archived!=archives_.end()){need(confirmed<=archived->second.through,"ack_ahead_of_server");return archived->second;}
        makeRoom();
        Source s; s.id=std::to_string(++nextId_); s.identity=identity; s.through=confirmed;
        if (confirmed) gap(s,{{"fromSeq",1},{"toSeq",confirmed},{"reason","server_restart_or_new_receiver"}});
        return sources_.emplace(key,std::move(s)).first->second;
    }
    Source& get(const j::object& identity, const std::string& instance) {
        auto key=sourceKey(identity,instance);auto it=sources_.find(key);
        if(it!=sources_.end())return it->second;
        auto old=archives_.find(key);need(old!=archives_.end(),"source_not_open");return old->second;
    }
    j::object summary(const Source& s) const {
        bool ended=s.end.is_object(); bool received=false;
        if (ended) { auto p=s.end.as_object().if_contains("latestEventSeq"); received=p && !p->is_null() && seq(*p)==s.through; }
        j::value collectorAck=nullptr;
        const auto& metadata=ended?s.end:s.status;
        if(metadata.is_object()) if(auto p=metadata.as_object().if_contains("collectorAck"))collectorAck=*p;
        bool cleanup=false;
        if(collectorAck.is_object()) if(auto p=collectorAck.as_object().if_contains("state"))cleanup=*p=="confirmed";
        auto age=[](Clock::time_point at)->j::value {
            if(at==Clock::time_point{})return nullptr;
            return std::chrono::duration<double>(Clock::now()-at).count();
        };
        auto receiptAge=age(s.receivedAt),statusAge=age(s.statusAt),snapshotAge=age(s.snapshotAt);
        auto connection=connections_.find(str(field(s.identity,"instanceId")));
        bool online=connection!=connections_.end() && connection->second==s.connectionId &&
            !receiptAge.is_null() && receiptAge.to_number<double>()<15;
        bool statusFresh=online && !statusAge.is_null() && statusAge.to_number<double>()<3;
        bool snapshotFresh=online && !snapshotAge.is_null() && snapshotAge.to_number<double>()<3;
        bool inactive=false,paused=false; std::string integrity="unknown";
        if(s.status.is_object()) {
            const auto& status=s.status.as_object();
            if(auto p=status.if_contains("active"))inactive=p->is_bool() && !p->as_bool();
            if(auto p=status.if_contains("paused"))paused=p->is_bool() && p->as_bool();
            if(auto p=status.if_contains("health");p && p->is_object()) {
                const auto& health=p->as_object();bool incomplete=false;
                if(auto c=health.if_contains("captureContinuous");c && c->is_bool())integrity=c->as_bool()?"complete_since_capture_start":"incomplete";
                for(auto k:{"captureErrorCount","droppedEventCount","rejectedRecordCount"})
                    if(auto n=health.if_contains(k);n && n->is_number() && n->to_number<double>()>0)incomplete=true;
                if(incomplete)integrity="incomplete";
            }
        }
        bool captureClosed=false;
        if(ended)if(auto p=s.end.as_object().if_contains("captureClosed"))captureClosed=p->is_bool() && p->as_bool();
        std::string lifecycle=ended?(inactive || received || captureClosed?"ended":"ending"):(!online?"offline":(paused?"paused":"running"));
        return {{"sourceId",s.id},{"createdOrder",std::stoull(s.id)},{"source",s.identity},{"receivedThrough",s.through},
            {"acceptedEvents",s.accepted},{"duplicateEvents",s.duplicates},{"retainedEvents",s.events.size()},
            {"historyStart",s.events.empty()?s.through+1:s.events.front().seq},{"historyIncomplete",s.historyIncomplete},
            {"snapshotCount",s.snapshotCount},{"sessionEnd",s.end},{"serverTailComplete",received},
            {"historyComplete",received && !s.historyIncomplete},{"collectorAck",collectorAck},
            {"transportComplete",received && !s.historyIncomplete},{"captureIntegrity",integrity},
            {"historyRetained",!s.archived && s.evictedEvents==0},{"evictedEvents",s.evictedEvents},{"archived",s.archived},
            {"online",online},{"statusFresh",statusFresh},{"snapshotFresh",snapshotFresh && !inactive && !ended},
            {"receivedAgeSec",receiptAge},{"statusAgeSec",statusAge},{"snapshotAgeSec",snapshotAge},{"lifecycle",lifecycle},
            {"collectorCleanupComplete",cleanup},{"gaps",s.gaps},{"hookStatus",s.status}};
    }
    j::array summaries() const {
        j::array a;for (const auto& [k,s]:sources_)a.push_back(summary(s));
        for(const auto& [k,s]:archives_)a.push_back(summary(s));
        return a;
    }
    Source* byId(const std::string& id) {
        for(auto& [k,s]:sources_)if(s.id==id)return &s;
        for(auto& [k,s]:archives_)if(s.id==id)return &s;
        return nullptr;
    }
    std::size_t bytes() const { return bytes_; }
    void events(Source& s, const j::object& batch) {
        auto after=seq(field(batch,"afterSeq")), through=seq(field(batch,"throughSeq")), latest=seq(field(batch,"latestEventSeq"));
        need(after<=s.through && after<=through && through<=latest,"event_cursor_gap");
        if(s.end.is_object() && !field(s.end.as_object(),"latestEventSeq").is_null())
            need(through<=seq(field(s.end.as_object(),"latestEventSeq")),"beyond_final_event");
        const auto& ev=field(batch,"events"); const auto& gs=field(batch,"gaps");
        need(ev.is_array() && gs.is_array() && ev.as_array().size()+gs.as_array().size()<=512,"event_batch_limit");
        struct Range { std::uint64_t from,to; const j::value* value; bool isGap; std::size_t size; };
        std::vector<Range> ranges;
        for(const auto& e:ev.as_array()) {
            const auto& o=obj(e); auto n=seq(field(o,"eventSeq")); str(field(o,"type"));
            auto size=j::serialize(e).size(); need(size<=32768,"event_record_limit");
            ranges.push_back({n,n,&e,false,size});
        }
        for(const auto& g:gs.as_array()) {
            const auto& o=obj(g); auto from=seq(field(o,"fromSeq")),to=seq(field(o,"toSeq"));
            need(from<=to,"invalid_gap"); str(field(o,"reason")); ranges.push_back({from,to,&g,true,0});
        }
        std::sort(ranges.begin(),ranges.end(),[](auto& a,auto& b){return a.from<b.from;});
        auto cursor=after;
        for(const auto& r:ranges) {
            need(r.from==cursor+1,"hidden_or_overlapping_gap"); cursor=r.to;
            if (!r.isGap && r.to<=s.through) {
                auto it=std::find_if(s.events.begin(),s.events.end(),[&](const auto& e){return e.seq==r.to;});
                if(it!=s.events.end()) need(it->value==*r.value,"conflicting_event");
                for(const auto& g:s.gaps) {
                    const auto& o=g.as_object();
                    if(str(field(o,"reason"))!="server_restart_or_new_receiver")
                        need(r.to<seq(field(o,"fromSeq")) || r.to>seq(field(o,"toSeq")),"event_conflicts_with_gap");
                }
            }
            if(r.isGap && r.from<=s.through) {
                for(const auto& e:s.events) need(e.seq<r.from || e.seq>r.to,"gap_conflicts_with_event");
            }
        }
        need(cursor==through,"invalid_through_sequence");
        // Validate the whole batch before advancing any state or acknowledging it.
        for(const auto& r:ranges) {
            if(r.to<=s.through) { if(!r.isGap) ++s.duplicates; continue; }
            if(r.isGap) {
                auto g=r.value->as_object(); g["fromSeq"]=s.through+1; gap(s,std::move(g));
            } else {
                s.events.push_back({r.to,*r.value,r.size}); s.bytes+=r.size; bytes_+=r.size; ++s.accepted;
            }
            s.through=r.to;
        }
        trim(s);
        if(bytes_>64*1024*1024) for(auto& [k,other]:sources_) trim(other);
    }
    void snapshot(Source& s, const j::object& page) {
        need(!s.archived,"source_archived");
        auto index=seq(field(page,"pageIndex")), count=seq(field(page,"pageCount"));
        need(count>0 && count<=64 && index<count,"snapshot_page_limit");
        auto id=str(field(page,"snapshotId")); number(field(page,"assembledSimTime")); seq(field(page,"eventSeqAtCapture"));
        seq(field(page,"scopeRevision")); obj(field(page,"coverage"));
        need(field(page,"entities").is_array(),"entities_required");
        if(index==0) { s.assembly=page; s.assembly["entities"]=j::array{}; s.nextPage=0; s.assemblyBytes=0; s.assemblyStarted=Clock::now(); }
        need(!s.assembly.empty() && Clock::now()-s.assemblyStarted<std::chrono::seconds(10),"snapshot_expired");
        need(s.nextPage==index && str(field(s.assembly,"snapshotId"))==id &&
             field(s.assembly,"pageCount")==field(page,"pageCount") &&
             field(s.assembly,"assembledSimTime")==field(page,"assembledSimTime") &&
             field(s.assembly,"scopeRevision")==field(page,"scopeRevision") &&
             field(s.assembly,"coverage")==field(page,"coverage") &&
             field(s.assembly,"eventSeqAtCapture")==field(page,"eventSeqAtCapture"),"mixed_snapshot");
        s.assemblyBytes+=j::serialize(page).size(); need(s.assemblyBytes<=8*1024*1024,"snapshot_size_limit");
        auto& all=s.assembly["entities"].as_array();
        for(const auto& e:field(page,"entities").as_array()) {
            need(j::serialize(e).size()<=32768,"entity_record_limit");
            const auto& o=obj(e); auto entityId=str(field(o,"entityId")); auto kind=str(field(o,"kind"));
            need(kind=="aircraft" || kind=="missile","entity_kind");
            field(o,"motion");
            if(kind=="aircraft") for(auto key:{"fuel","armament","occupancy","identity"}) field(o,key);
            else for(auto key:{"launch","targetObservation","lastKnownTarget"}) field(o,key);
            for(const auto& old:all) need(str(field(old.as_object(),"entityId"))!=entityId,"duplicate_entity");
            all.push_back(e);
        }
        ++s.nextPage;
        if(s.nextPage==count) {
            bool newer=s.snapshot.is_null() || number(field(s.assembly,"assembledSimTime"))>=number(field(s.snapshot.as_object(),"assembledSimTime"));
            if(newer && (s.snapshot.is_null() || field(s.snapshot.as_object(),"snapshotId")!=field(s.assembly,"snapshotId"))) {
                s.snapshot=s.assembly; ++s.snapshotCount;s.snapshotAt=Clock::now();
            }
            s.assembly.clear(); s.assemblyBytes=0;
        }
    }
    void end(Source& s, const j::object& details) {
        auto final=field(details,"latestEventSeq");
        if(!final.is_null()) need(seq(final)>=s.through,"final_before_received");
        need(field(details,"tailComplete").is_bool(),"tail_complete_required");
        if(field(details,"tailComplete").as_bool()) need(!final.is_null() && seq(field(details,"readThrough"))==seq(final),"invalid_tail_complete");
        if(s.end.is_object() && !field(s.end.as_object(),"latestEventSeq").is_null())
            need(field(s.end.as_object(),"latestEventSeq")==final,"final_changed");
        s.end=details;
    }
};
}
