local Json=require("src.shared.json")
local Recorder=require("src.hook.recorder")

test("failed diagnostic writes remain limited to one attempt per second per periodic file",function()
    local time,attempts=0,0
    local recorder=Recorder.new(Json,"unused",{now=function() return time end,
        io={open=function() attempts=attempts+1; return nil,"disk unavailable" end}})
    local source={missionSessionId="m",collectorEpoch="e"}
    equal(recorder:onState(source,{}),false); equal(recorder:onStatus({}),false)
    equal(attempts,2)
    for _=1,9 do time=time+0.1; recorder:onState(source,{}); recorder:onStatus({}) end
    equal(attempts,2)
    time=1; recorder:onState(source,{}); recorder:onStatus({}); equal(attempts,4)
    recorder:onStatus({},true); equal(attempts,5) -- Final status is still forced at a lifecycle boundary.
end)
test("recorder closes files and refuses acceptance on write/flush failures",function()
    for _,mode in ipairs({"write_error","write_nil","flush_error","close_error"}) do
        local closed=false
        local file={
            write=function()
                if mode=="write_error" then error("disk failed") end
                if mode=="write_nil" then return nil,"disk full" end
                return true
            end,
            flush=function() if mode=="flush_error" then error("flush failed") end; return true end,
            close=function() closed=true; if mode=="close_error" then error("close failed") end; return true end
        }
        local recorder=Recorder.new(Json,"unused",{io={open=function() return file end}})
        equal(recorder:onEvents({missionSessionId="m",collectorEpoch="e"},{events=Json.array()}),false)
        truth(closed)
    end
end)
test("successful diagnostic recording does not return an implicit ACK",function()
    local written
    local file={write=function(_,text) written=text; return true end,flush=function() return true end,close=function() return true end}
    local recorder=Recorder.new(Json,"unused",{io={open=function() return file end}})
    local accepted,receipt=recorder:onEvents({missionSessionId="m",collectorEpoch="e"},{throughSeq=7,events=Json.array()})
    equal(accepted,true); equal(receipt,nil)
    local body=Json.decode(written); equal(body.missionSessionId,"m"); equal(body.eventLog.throughSeq,7)
end)

test("nil-success host I/O is accepted only after exact byte verification",function()
    local contents,closed="",0
    local ioBinding={open=function(_,mode)
        if mode=="wb" then contents="" end
        if mode=="wb" or mode=="ab" then
            return {write=function(_,payload) contents=contents..payload end,
                flush=function() end,close=function() closed=closed+1 end}
        end
        local position=0
        return {seek=function(_,origin,offset)
                if origin=="end" then position=#contents+offset else position=offset end
                return position
            end,
            read=function(_,bytes) local value=contents:sub(position+1,position+bytes); position=position+#value; return value end,
            close=function() closed=closed+1 end}
    end}
    local recorder=Recorder.new(Json,"unused",{io=ioBinding})
    local accepted,receipt=recorder:onEvents({missionSessionId="m",collectorEpoch="e"},{throughSeq=1,events=Json.array()})
    equal(accepted,true); equal(receipt,nil); equal(closed,2)
    equal(Json.decode(contents).eventLog.throughSeq,1)
end)

test("a nil I/O result without bytes is not mistaken for successful recording",function()
    local recorder=Recorder.new(Json,"unused",{io={open=function(_,mode)
        if mode=="rb" then
            return {seek=function() return 0 end,read=function() return "" end,close=function() end}
        end
        return {write=function() end,flush=function() end,close=function() end}
    end}})
    local accepted,err=recorder:onStatus({phase="collecting"},true)
    equal(accepted,false); truth(err:find("byte verification failed",1,true))
end)

test("recorder reports the actual failed I/O stage and exception",function()
    local recorder=Recorder.new(Json,"unused",{io={open=function()
        return {write=function() return true end,flush=function() error("host flush exception") end,close=function() return true end}
    end}})
    local accepted,err=recorder:onStatus({phase="collecting"},true)
    equal(accepted,false); truth(err:find("flush exception",1,true)); truth(err:find("host flush exception",1,true))
end)
