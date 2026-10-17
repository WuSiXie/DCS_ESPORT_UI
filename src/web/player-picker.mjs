import {escape as e} from './stream.mjs';
import {telemetryFresh} from './telemetry.mjs';

export function playerDirectory(state,now=Date.now()) {
  const names=new Set(state.history??[]),online=new Set(),fresh=telemetryFresh(state,state.localStatus,now,false);
  for(const record of state.players??[])if(record.name){names.add(record.name);if(fresh&&record.connected===true)online.add(record.name);}
  for(const record of state.aircraftLedger??[]){const name=record.lastPlayerName??record.entity?.occupancy?.playerName;if(name)names.add(name);}
  for(const entity of state.snapshot?.entities??[])if(entity.occupancy?.isPlayer&&entity.occupancy.playerName)names.add(entity.occupancy.playerName);
  return [...names].filter(n=>typeof n==='string'&&n.length>0&&n.length<=128).map(name=>({name,online:online.has(name)}))
    .sort((a,b)=>Number(b.online)-Number(a.online)||a.name.localeCompare(b.name,'zh-CN'));
}

export function mountPlayerPicker({getState,getDraft,addPlayer,canEdit}) {
  const box=document.createElement('aside');box.className='player-picker';box.hidden=true;box.role='dialog';box.setAttribute('aria-label','在线与历史选手');
  box.innerHTML='<header><strong>在线与历史选手</strong><button type="button" aria-label="关闭选手小窗">×</button></header><p>拖动选手到任一选手池，或点击队伍按钮加入。</p><input type="search" placeholder="搜索选手名称" aria-label="搜索选手名称"><div class="picker-list"></div><small>在线以当前任务的 DCS 连接记录为准；历史为本次控制台会话已观察到的选手。</small>';
  document.body.append(box);let dragging=false,last='',move=null;
  const list=box.querySelector('.picker-list');
  function refresh(){
    if(box.hidden||dragging)return;
    const q=box.querySelector('input').value.trim().toLocaleLowerCase(),c=getDraft();if(!c)return;
    const rows=playerDirectory(getState()).filter(r=>r.name.toLocaleLowerCase().includes(q));
    const markup=rows.map(r=>`<div class="picker-player" draggable="${canEdit()}" data-player="${e(r.name)}"><span class="presence ${r.online?'online':''}">${r.online?'在线':'历史'}</span><strong>${e(r.name)}</strong><div>${['blue','red'].map(side=>`<button type="button" data-team="${side}" ${canEdit()?'':'disabled'} title="加入${e(c.match[side+'Name'])}">${e(c.match[side+'Name'])}</button>`).join('')}</div></div>`).join('')||'<p>没有匹配的选手记录</p>';
    if(markup!==last){list.innerHTML=markup;last=markup;}
  }
  box.querySelector('header button').onclick=()=>{box.hidden=true;};box.querySelector('input').oninput=refresh;
  box.addEventListener('click',ev=>{const button=ev.target.closest('[data-team]');if(button&&canEdit())addPlayer(ev.target.closest('[data-player]').dataset.player,button.dataset.team);});
  box.addEventListener('dragstart',ev=>{const row=ev.target.closest('[data-player]');if(!row||!canEdit()){ev.preventDefault();return;}dragging=true;ev.dataTransfer.effectAllowed='copy';ev.dataTransfer.setData('application/x-dcs-player',row.dataset.player);});
  box.addEventListener('dragend',()=>{dragging=false;refresh();});
  const header=box.querySelector('header');header.addEventListener('pointerdown',ev=>{if(ev.target.closest('button')||ev.button!==0)return;const r=box.getBoundingClientRect();move={x:ev.clientX-r.left,y:ev.clientY-r.top};header.setPointerCapture(ev.pointerId);});
  header.addEventListener('pointermove',ev=>{if(!move)return;box.style.left=Math.max(0,Math.min(innerWidth-box.offsetWidth,ev.clientX-move.x))+'px';box.style.top=Math.max(0,Math.min(innerHeight-60,ev.clientY-move.y))+'px';});
  header.addEventListener('pointerup',()=>move=null);header.addEventListener('pointercancel',()=>move=null);
  const timer=setInterval(refresh,1000);
  return {open(){box.hidden=false;refresh();box.querySelector('input').focus();},refresh,dispose(){clearInterval(timer);box.remove();}};
}
