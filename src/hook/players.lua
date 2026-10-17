-- Public multiplayer presence only; no UCID or IP leaves the Hook.
local Players={};Players.__index=Players
function Players.new(deps)
    return setmetatable({deps=deps,records={},sequence=0,nextPoll=0,payload={supported=false,records=deps.Json.array()}},Players)
end
function Players:reset() self.records={};self.nextPoll=0;self:publish(false) end
function Players:publish(supported)
    local list=self.deps.Json.array()
    for _,r in pairs(self.records) do list[#list+1]=r end
    table.sort(list,function(a,b)return a.changed>b.changed end)
    while #list>256 do local old=table.remove(list);self.records[old.id]=nil end
    self.payload={supported=supported,sequence=self.sequence,records=list}
end
function Players:update(id,info)
    if type(info)~='table' or type(info.name)~='string' or info.name=='' then return end
    local old=self.records[id];local slot=tostring(info.slot or '')
    local changed=not old or old.name~=info.name or not old.connected or old.slot~=slot or old.side~=info.side
    if changed then self.sequence=self.sequence+1 end
    self.records[id]={id=id,name=info.name,side=info.side,slot=slot,connected=true,
        generation=old and old.name==info.name and (old.connected and old.generation or old.generation+1) or 1,
        disconnects=old and old.name==info.name and old.disconnects or 0,changed=changed and self.sequence or old.changed}
end
function Players:disconnect(id)
    local old=self.records[id]
    if not old then local ok,info=pcall(self.deps.net.get_player_info,id);if ok then self:update(id,info) end;old=self.records[id] end
    if old and old.connected then
        self.sequence=self.sequence+1;old.connected=false;old.disconnects=old.disconnects+1;old.changed=self.sequence
    end
    self:publish(self.payload.supported)
end
function Players:tick()
    local now=self.deps.now();if now<self.nextPoll then return end;self.nextPoll=now+1
    local net=self.deps.net
    if not net or type(net.get_player_list)~='function' or type(net.get_player_info)~='function' then self:publish(false);return end
    local ok,list=pcall(net.get_player_list)
    if not ok or type(list)~='table' then self:publish(false);return end
    -- Missing rows never imply a disconnect: only onPlayerDisconnect does.
    for _,id in pairs(list) do local success,info=pcall(net.get_player_info,id);if success then self:update(id,info) end end
    self:publish(true)
end
return Players
