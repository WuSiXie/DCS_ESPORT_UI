-- Hook-only nonblocking TCP transport. Never installed into the mission state.
local Transport = {}
Transport.__index = Transport
local function sourceKey(s) return #s.missionSessionId .. ":" .. s.missionSessionId .. #s.collectorEpoch .. ":" .. s.collectorEpoch end
local function integer(n) return type(n)=="number" and n>=0 and n%1==0 and n<=9007199254740991 end
local function frame(text)
    local n=#text
    return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)..text
end
function Transport.new(deps, config)
    assert(config.host==nil or config.host=="127.0.0.1","Hook TCP must use loopback")
    assert(type(config.token)=="string" and #config.token>=32 and #config.token<=256,"Network token must contain 32..256 characters")
    assert(type(config.instanceId)=="string" and #config.instanceId>0 and #config.instanceId<=256,"Invalid instanceId")
    assert(config.ackMode=="memory","Explicit ackMode=memory required")
    assert(config.port==nil or (integer(config.port) and config.port>0 and config.port<65536),"Invalid TCP port")
    return setmetatable({deps=deps,config=config,Json=deps.Json,bridge=deps.bridge,sessions={},ends={},endOrder={},
        phase="disconnected",retryAt=0,backoff=0.5,rx="",lastScan=-math.huge,nextStatus=0,nextPing=0,
        snapshotQueue={},snapshotIndex=1,sessionIndex=0,connections=0,bytesSent=0,bytesReceived=0},Transport)
end
function Transport:_notice(message)
    self.lastError=message
    if self.lastNotice~=message then self.lastNotice=message;if self.deps.log then self.deps.log("TCP: "..message) end end
end
function Transport:_disconnect(reason)
    if self.socket then pcall(self.socket.close,self.socket) end
    self.socket=nil;self.phase="disconnected";self.tx=nil;self.rx="";self.want=nil;self.connectionId=nil
    self.snapshotQueue={};self.snapshotIndex=1;self.lastSnapshot=nil;self.dataBurst=0
    for _,s in pairs(self.sessions) do s.open=false;s.opening=false;s.inflight=nil end
    for _,e in pairs(self.ends) do e.received=false;e.sent=false end
    self.retryAt=self.deps.now()+self.backoff;self.backoff=math.min(self.backoff*2,10)
    self:_notice(reason)
end
function Transport:_identity(source)
    return {instanceId=self.config.instanceId,missionSessionId=source.missionSessionId,collectorEpoch=source.collectorEpoch}
end
function Transport:_message(kind, payload, source)
    local m={transportVersion=1,type=kind,connectionId=self.connectionId or self.Json.null,payload=payload}
    if source then m.source=self:_identity(source) end
    local text=self.Json.encode(m);assert(#text<=524288,"TCP frame exceeds 512 KiB")
    return frame(text)
end
function Transport:_queue(kind,payload,source,done)
    assert(not self.tx,"Only one frame may be sent at a time")
    self.tx={data=self:_message(kind,payload,source),position=1,done=done}
end
function Transport:_scan()
    local b=self.bridge;local live={}
    local function add(source,read,confirmed)
        if not source then return end
        local key=sourceKey(source);live[key]=true
        local s=self.sessions[key]
        if not s then s={source=self.Json.copy(source),confirmed=confirmed};self.sessions[key]=s end
        s.read=read;s.confirmed=math.max(s.confirmed or 0,confirmed);s.bridgePresent=true
    end
    add(b.source,b.readThrough,b.confirmedSeq)
    for _,old in ipairs(b:getRetainedSessions()) do add(old.source,old.readThrough,old.confirmedSeq) end
    for key,s in pairs(self.sessions) do
        if not live[key] then s.bridgePresent=false;if not self.ends[key] then self.sessions[key]=nil end end
    end
    for key,e in pairs(self.ends) do
        if not self.sessions[key] then self.sessions[key]={source=e.source,read=e.details.readThrough,confirmed=e.confirmed or 0} end
    end
    self.lastScan=self.deps.now()
end
function Transport:onSessionEnd(source,details)
    local key=sourceKey(source)
    if not self.ends[key] then
        if #self.endOrder>=64 then
            local remove
            for i,k in ipairs(self.endOrder) do if self.ends[k].received then remove=i;break end end
            if not remove then self:_notice("Session end queue full; final metadata not retained");return false end
            local old=table.remove(self.endOrder,remove);self.ends[old]=nil
        end
        self.endOrder[#self.endOrder+1]=key
    end
    local previous=self.ends[key]
    self.ends[key]={source=self.Json.copy(source),details=self.Json.copy(details),
        confirmed=previous and previous.confirmed or details.confirmedSeq or 0,received=false,sent=false}
    self.lastScan=-math.huge
    return true
end
function Transport:onStatus(_, urgent)
    if urgent then self.nextStatus = 0 end
    return true
end
function Transport:_receive(m)
    assert(type(m)=="table" and m.transportVersion==1,"Invalid server message")
    if m.type=="welcome" then
        assert(self.phase=="handshake" and type(m.connectionId)=="string" and type(m.serverEpoch)=="string" and m.ackMode=="memory","Invalid memory handshake")
        self.connectionId=m.connectionId;self.serverEpoch=m.serverEpoch;self.phase="ready"
        self.backoff=0.5;self.lastError=nil;self.lastNotice=nil;self.connections=self.connections+1
        self.nextStatus=0;self.nextPing=self.deps.now()+5
        if self.deps.log then self.deps.log("TCP connected; memory ACK; serverEpoch="..m.serverEpoch) end
        return
    end
    assert(self.phase=="ready" and m.connectionId==self.connectionId and m.serverEpoch==self.serverEpoch and m.ackMode=="memory","Stale server confirmation")
    if m.type=="pong" then return end
    assert(type(m.source)=="table" and m.source.instanceId==self.config.instanceId,"ACK instance mismatch")
    local key=sourceKey(m.source);local s=assert(self.sessions[key],"Unknown ACK source")
    if m.type=="source_ready" or m.type=="ack" then
        local n=m.payload.ackEventSeq
        assert(integer(n) and n<=s.read,"ACK exceeds accepted data")
        if m.type=="source_ready" then assert(s.opening,"Unsolicited source readiness");s.open=true;s.opening=false end
        if n>s.confirmed and s.bridgePresent then
            local ok,err=self.bridge:confirm(s.source,n);assert(ok,err)
        end
        s.confirmed=math.max(s.confirmed,n)
        if s.inflight and n>=s.inflight then s.inflight=nil end
        if self.ends[key] then
            local e=self.ends[key];e.confirmed=s.confirmed
            -- Old sources can receive their server ACK after a new mission started.
            -- Refresh delivery metadata without querying the new mission environment.
            if e.details.confirmedSeq ~= s.confirmed then
                e.details.confirmedSeq=s.confirmed
                if s.confirmed>=e.details.readThrough then e.details.pendingItems=0 end
                if type(e.details.collectorAck)=="table" then e.details.collectorAck.confirmedSeq=s.confirmed end
                e.received=false;e.sent=false
            end
        end
    elseif m.type=="session_end_received" then
        local e=self.ends[key]
        if e and self.Json.encode(e.details)==self.Json.encode(m.payload) then e.received=true end
    else error("Unknown server message") end
end
function Transport:_read(budget,deadline)
    local messages=0
    while budget>0 and messages<4 and self.deps.cpuNow()<deadline do
        local needed=(self.want or 4)-#self.rx
        local data,err,partial=self.socket:receive(math.min(needed,budget))
        data=data or partial or "";self.rx=self.rx..data;budget=budget-#data;self.bytesReceived=self.bytesReceived+#data
        if #data>0 then self.lastReceive=self.deps.now() end
        if #self.rx==(self.want or 4) then
            if not self.want then
                local a,b,c,d=self.rx:byte(1,4);self.want=((a*256+b)*256+c)*256+d
                assert(self.want>0 and self.want<=524288,"Server frame limit");self.rx=""
            else
                local text=self.rx;self.rx="";self.want=nil;messages=messages+1
                self:_receive(self.Json.decode(text))
            end
        end
        if err and err~="timeout" then error("TCP receive: "..err) end
        if #data==0 then break end
    end
end
function Transport:_snapshots()
    local state=self.bridge.latestState;local source=self.bridge.source
    if not state or not source or self.lastSnapshot==state.snapshotId then return end
    local s=self.sessions[sourceKey(source)];if not s or not s.open then return end
    local groups,current,bytes,total={},self.Json.array(),0,0
    for _,record in ipairs(state.entities) do
        local size=#self.Json.encode(record);assert(size<=32768,"Entity record limit")
        if bytes+size>400000 and #current>0 then groups[#groups+1]=current;current=self.Json.array();bytes=0 end
        current[#current+1]=record;bytes=bytes+size;total=total+size
    end
    assert(total<=8*1024*1024,"Snapshot aggregate limit")
    if #current>0 or #groups==0 then groups[#groups+1]=current end
    assert(#groups<=64,"Snapshot page limit")
    self.snapshotQueue={};self.snapshotIndex=1
    for i,records in ipairs(groups) do
        local page={snapshotId=state.snapshotId,pageIndex=i-1,pageCount=#groups,entities=records,
            assembledSimTime=state.assembledSimTime,eventSeqAtCapture=state.eventSeqAtCapture,
            scopeRevision=state.scopeRevision,coverage=state.coverage}
        self.snapshotQueue[#self.snapshotQueue+1]=self:_message("snapshot",page,source)
    end
    self.lastSnapshot=state.snapshotId
end
function Transport:_control(now)
    if now>=self.nextPing then self.nextPing=now+5;self.dataBurst=0;self:_queue("ping",{});return true end
    if now>=self.nextStatus and self.bridge.source then
        local s=self.sessions[sourceKey(self.bridge.source)]
        if s and s.open then
            local status=self.bridge:getStatus()
            if self.deps.players then status.players=self.deps.players.payload end
            self.nextStatus=now+1;self.dataBurst=0;self:_queue("status",status,s.source);return true
        end
    end
    return false
end
function Transport:_schedule()
    if self.tx or self.phase~="ready" then return end
    local now=self.deps.now()
    if now-self.lastScan>=0.05 then self:_scan() end
    -- Tail events get the first opportunity, but continuous event traffic can
    -- defer due controls by at most four data frames. Snapshots never defer them.
    if (self.dataBurst or 0)>=4 and self:_control(now) then return end
    local keys={};for key in pairs(self.sessions) do keys[#keys+1]=key end;table.sort(keys)
    for offset=1,#keys do
        local i=(self.sessionIndex+offset-1)%#keys+1;local key=keys[i];local s=self.sessions[key]
        if not s.open and not s.opening then
            s.opening=true;self.sessionIndex=i;self.dataBurst=(self.dataBurst or 0)+1
            self:_queue("source_open",{confirmedSeq=s.confirmed,readThrough=s.read},s.source);return
        end
        if s.inflight and now-s.inflightAt>5 then error("Event ACK timeout") end
        if s.open and not s.inflight and s.bridgePresent and s.read>s.confirmed then
            for _,batch in ipairs(self.bridge:getPendingBatches(s.source,1)) do
                if batch.throughSeq>s.confirmed then
                    s.inflight=batch.throughSeq;s.inflightAt=now;self.sessionIndex=i;self.dataBurst=(self.dataBurst or 0)+1
                    self:_queue("events",batch,s.source);return
                end
            end
        end
        local e=self.ends[key]
        if s.open and e and not e.received and (not e.sent or now-e.sent>2) then
            e.sent=now;self.sessionIndex=i;self.dataBurst=(self.dataBurst or 0)+1;self:_queue("session_end",e.details,s.source);return
        end
    end
    if self:_control(now) then return end
    if self.snapshotIndex>#self.snapshotQueue then self:_snapshots() end
    if self.snapshotIndex<=#self.snapshotQueue then
        self.tx={data=self.snapshotQueue[self.snapshotIndex],position=1};self.snapshotIndex=self.snapshotIndex+1;return
    end
end
function Transport:_tick()
    local now=self.deps.now();local deadline=self.deps.cpuNow()+0.001
    if not self.socket then
        if now<self.retryAt then return end
        local sock,err=self.deps.socket.tcp();assert(sock,err);self.socket=sock
        assert(sock:settimeout(0));self.connectStarted=now;self.phase="connecting"
        sock:connect(self.config.host or "127.0.0.1",self.config.port or 9081)
    end
    if self.phase=="connecting" then
        local _,writable=self.deps.socket.select({},{self.socket},0)
        if not writable or #writable==0 then assert(now-self.connectStarted<5,"Connect timeout");return end
        local peer=self.socket:getpeername();assert(peer,"Connection refused")
        self.phase="handshake";self.lastReceive=now
        self:_queue("hello",{instanceId=self.config.instanceId,token=self.config.token,ackMode="memory"})
    end
    assert(now-(self.lastReceive or now)<15,"Server heartbeat timeout")
    self:_read(65536,deadline)
    local budget=65536;local messages=0
    while budget>0 and messages<4 and self.deps.cpuNow()<deadline do
        self:_schedule();if not self.tx then break end
        local tx=self.tx;local last=math.min(#tx.data,tx.position+budget-1)
        local sent,err,partial=self.socket:send(tx.data,tx.position,last)
        local position=sent or partial or (tx.position-1)
        local bytes=math.max(0,position-tx.position+1);budget=budget-bytes;self.bytesSent=self.bytesSent+bytes
        tx.position=position+1
        if tx.position>#tx.data then self.tx=nil;messages=messages+1;if tx.done then tx.done() end end
        if err and err~="timeout" then error("TCP send: "..err) end
        if bytes==0 then break end
    end
end
function Transport:tick()
    local ok,err=pcall(self._tick,self)
    if not ok then self:_disconnect(tostring(err)) end
end
function Transport:boundary()
    -- Bounded best effort only; never wait/sleep for network I/O in DCS.
    local deadline=self.deps.cpuNow()+0.01
    for _=1,16 do if self.deps.cpuNow()>=deadline then break end;self:tick() end
end
function Transport:status()
    local pendingEnds=0;for _,e in pairs(self.ends) do if not e.received then pendingEnds=pendingEnds+1 end end
    return {phase=self.phase,serverEpoch=self.serverEpoch or self.Json.null,ackMode="memory",lastError=self.lastError or self.Json.null,
        connections=self.connections,bytesSent=self.bytesSent,bytesReceived=self.bytesReceived,pendingSessionEnds=pendingEnds}
end
return Transport
