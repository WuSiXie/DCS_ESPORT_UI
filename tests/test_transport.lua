local Json=require("src.shared.json")
local Transport=require("src.hook.transport")
local function fixture()
    local receipts={}
    local b={getRetainedSessions=function() return {} end,
        confirm=function(_,source,n) receipts[#receipts+1]={source=source,n=n};return true end}
    local t=Transport.new({Json=Json,bridge=b,now=function() return 0 end,cpuNow=function() return 0 end},
        {token=string.rep("a",32),instanceId="test",ackMode="memory"})
    local source={missionSessionId="m",collectorEpoch="e"}
    t.sessions["1:m1:e"]={source=source,read=5,confirmed=0,opening=true,bridgePresent=true}
    t.phase="handshake"
    t:_receive({transportVersion=1,type="welcome",connectionId="c",serverEpoch="server",ackMode="memory"})
    local function ack(n)
        return {transportVersion=1,type="ack",connectionId="c",serverEpoch="server",ackMode="memory",
            source={instanceId="test",missionSessionId="m",collectorEpoch="e"},payload={ackEventSeq=n}}
    end
    return t,receipts,ack
end
test('removed camera control messages cannot execute or acknowledge events',function()
    local t,r,ack=fixture()
    local m=ack(0);m.type='camera_control';m.payload={revision=1,nativeEnabled=true,transparent=true}
    raises(function()t:_receive(m)end);equal(#r,0)
    t:_receive(ack(3));equal(#r,1);equal(r[1].n,3)
end)

test("network ACK rejects stale connections, epochs, instances, sources and unsafe cursors",function()
    local t,r,ack=fixture()
    for _,field in ipairs({"connectionId","serverEpoch","ackMode"}) do
        local m=ack(2);m[field]="wrong";raises(function() t:_receive(m) end)
    end
    for _,field in ipairs({"instanceId","missionSessionId","collectorEpoch"}) do
        local m=ack(2);m.source[field]="wrong";raises(function() t:_receive(m) end)
    end
    for _,n in ipairs({-1,1.5,6}) do raises(function() t:_receive(ack(n)) end) end
    equal(#r,0)
    t:_receive(ack(3));t:_receive(ack(3));t:_receive(ack(2))
    equal(#r,1);equal(r[1].n,3);equal(t.sessions["1:m1:e"].confirmed,3)
end)
test("late old-source ACK refreshes end metadata and ignores its obsolete echo",function()
    local t,r,ack=fixture()
    local source=t.sessions["1:m1:e"].source
    local details={latestEventSeq=5,readThrough=5,confirmedSeq=0,actualAck=3,pendingItems=2,
        collectorAck={state="unverified",confirmedSeq=0,actualAck=3,lastError="mission_environment_replaced"}}
    t:onSessionEnd(source,details)
    t:_receive(ack(5))
    local e=t.ends["1:m1:e"]
    equal(e.details.confirmedSeq,5);equal(e.details.pendingItems,0)
    equal(e.details.collectorAck.confirmedSeq,5);equal(e.details.collectorAck.actualAck,3)
    equal(e.details.collectorAck.state,"unverified")
    local echo=ack(5);echo.type="session_end_received";echo.payload=details
    t:_receive(echo);equal(e.received,false)
    echo.payload=Json.copy(e.details);t:_receive(echo);equal(e.received,true)
end)

test("network parser preserves a welcome fragmented into individual bytes",function()
    local t=fixture();t.phase="handshake";t.connectionId=nil
    local value={transportVersion=1,type="welcome",connectionId="new",serverEpoch="next",ackMode="memory"}
    local body=Json.encode(value);local n=#body
    local input=string.char(0,0,math.floor(n/256),n%256)..body
    local pos=1
    t.socket={receive=function(_,count)
        if pos>#input then return nil,"timeout","" end
        local c=input:sub(pos,pos);pos=pos+1
        if count==1 then return c end
        return nil,"timeout",c
    end}
    t:_read(65536,1)
    equal(t.phase,"ready");equal(t.connectionId,"new");equal(t.serverEpoch,"next")
end)

test("continuous snapshots cannot starve heartbeat or source status",function()
    local t=fixture();local clock=0;t.deps.now=function()return clock end
    t.sessions={};t.bridge.source={missionSessionId="m",collectorEpoch="e"}
    t.bridge.readThrough=0;t.bridge.confirmedSeq=0;t.bridge.getStatus=function()return {}end
    t.sessions["1:m1:e"]={source=t.bridge.source,read=0,confirmed=0,open=true}
    local counts={}
    for i=1,200 do
        clock=i/10;t.bridge.latestState={snapshotId="s"..i,entities=Json.array(),assembledSimTime=clock,
            eventSeqAtCapture=0,scopeRevision=1,coverage={}}
        t:_schedule()
        if t.tx then local m=Json.decode(t.tx.data:sub(5));counts[m.type]=(counts[m.type] or 0)+1;t.tx=nil end
    end
    truth(counts.ping>=3);truth(counts.status>=15);truth(counts.snapshot>100)
end)

test("tail events precede due controls without starving controls under event load",function()
    local t,receipts,ack=fixture();local clock=0;local b=t.bridge
    b.source={missionSessionId="m",collectorEpoch="e"};b.readThrough=5;b.confirmedSeq=0
    b.getStatus=function()return {}end
    b.getPendingBatches=function()return {{afterSeq=b.confirmedSeq,throughSeq=b.readThrough,
        latestEventSeq=b.readThrough,events=Json.array(),gaps=Json.array()}} end
    b.confirm=function(_,_,n)b.confirmedSeq=n;return true end
    t.sessions["1:m1:e"].open=true;t.sessions["1:m1:e"].opening=false
    t.deps.now=function()return clock end;t.nextStatus=0;t.nextPing=0
    local types={}
    for i=1,6 do
        clock=i*.1;b.readThrough=b.readThrough+1;t:_schedule()
        local m=Json.decode(t.tx.data:sub(5));types[i]=m.type;t.tx=nil
        if m.type=="events" then t:_receive(ack(m.payload.throughSeq)) end
    end
    equal(types[1],"events");equal(types[5],"ping")
end)
test("network partial writes resume at the next byte without repeating frame data",function()
    local t=fixture();t.sessions={};t.nextStatus=100;t.nextPing=100;t.lastReceive=0
    local parts={};local clock=0
    t.deps.cpuNow=function() clock=clock+0.0003;return clock end
    t.socket={receive=function() return nil,"timeout","" end,
        send=function(_,data,first,last)
            local finish=math.min(last,first+2);parts[#parts+1]=data:sub(first,finish)
            return nil,"timeout",finish
        end}
    t:_queue("ping",{});local expected=t.tx.data
    for _=1,1000 do t:_tick();if not t.tx then break end end
    equal(t.tx,nil);equal(table.concat(parts),expected)
end)
