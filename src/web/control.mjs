import {mountPlateControls} from './plate-controls.mjs';
import { eventStream, escape as e, connectionLabel, lifecycleLabel } from './stream.mjs';
import { EVENT_LABELS, entityName, eventText, missionTime } from './telemetry.mjs';

const $=selector=>document.querySelector(selector);
let session=null,data=null,selected=null,draft=null,revision=null,dirty=false,stopStream=null,toastTimer,previewUrl='',lastSourceSignature='';
const playerHistory=new Set();let controlLocalStatus='connecting';
let featureBusy=false,featureQueue={},saving=false,editing=false,editingDetails=false,plateControls=null;
function preview(){if(draft)$('#preview').contentWindow?.postMessage({type:'dcs-preview',config:draft,editing,editingDetails},location.origin);}
$('#preview').addEventListener('load',preview);
addEventListener('toggle-element-details',()=>{editing=true;editingDetails=!editingDetails;preview();toast(editingDetails?'正在编辑内部元素':'正在编辑整体组件');});
addEventListener('toggle-dock-editor',()=>{editing=!editing;preview();toast(editing?'预览拖动已开启，修改后点击保存':'预览拖动已关闭');});
addEventListener('message',ev=>{if(ev.origin!==location.origin||ev.source!==$('#preview').contentWindow||ev.data?.type!=='dcs-dock-change'||!draft||!editing||session?.user.role==='viewer')return;const {nameplates,docks,elementLayouts}=ev.data;draft.nameplates=nameplates;draft.docks=docks;draft.elementLayouts=elementLayouts;changed();plateControls?.render();});
const layouts={overview:'比赛直播',tactical:'紧凑阵容'};
function toast(message){$('#toast').textContent=message;$('#toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').hidden=true,3500);}
async function api(path,{method='GET',body}={}) {
  let response;
  try{response=await fetch(path,{method,headers:{'Content-Type':'application/json',...(session?{'X-CSRF-Token':session.csrf}:{})},body:body===undefined?undefined:JSON.stringify(body)});}catch{throw new Error('本地服务连接失败');}
  const value=await response.json();if(!response.ok){if(response.status===401&&path!=='/api/login')showLogin();throw new Error(value.error??'请求失败');}return value;
}
function showLogin(){editing=false;editingDetails=false;plateControls?.dispose();plateControls=null;playerHistory.clear();stopStream?.();stopStream=null;session=null;data=null;selected=null;draft=null;dirty=false;previewUrl='';$('#preview').src='about:blank';$('#workspace').hidden=true;$('#login-screen').hidden=false;}
async function enter(){
  session=await api('/api/session');$('#login-screen').hidden=true;$('#workspace').hidden=false;
  $('#username').textContent=`${session.user.username} · ${{admin:'管理员',director:'导播',viewer:'只读'}[session.user.role]}`;
  for(const id of ['#new-output','#duplicate','#save','#cancel-preview'])$(id).disabled=session.user.role==='viewer';
  stopStream?.();stopStream=eventStream('/api/control/stream',{onState:receive,onStatus:status=>{
    controlLocalStatus=status;
    if(status==='unauthorized'){toast('登录已过期，请重新登录');showLogin();}
    else if(status==='offline'){$('#connection').textContent='本地连接中断 · 重连中';$('#connection').className='pill offline';}
  }});
}
$('#login-form').addEventListener('submit',async event=>{
  event.preventDefault();const button=event.target.querySelector('button');button.disabled=true;$('#login-error').textContent='';
  const form=new FormData(event.target);
  try{await api('/api/login',{method:'POST',body:{username:form.get('username'),password:form.get('password')}});event.target.elements.password.value='';await enter();}
  catch(error){$('#login-error').textContent=error.message;}finally{button.disabled=false;}
});
$('#logout').addEventListener('click',async()=>{try{await api('/api/logout',{method:'POST'});showLogin();}catch(error){toast(error.message);}});
function current(){return data?.outputs.find(output=>output.id===selected);}
function source(){if(!draft)return null;return draft.followLatest?[...data.sources].sort((a,b)=>b.createdOrder-a.createdOrder)[0]:draft.sourceEpoch===data.serverEpoch?data.sources.find(s=>s.sourceId===draft.sourceId):null;}
function state(){return data?.states[source()?.sourceId];}
function receive(value){
  data=value;
  for(const source of value.sources??[])for(const r of source.hookStatus?.players?.records??[])if(r.name)playerHistory.add(r.name);
  for(const state of Object.values(value.states??{}))for(const r of state.aircraftLedger??[]){const name=r.lastPlayerName??r.entity?.occupancy?.playerName;if(name)playerHistory.add(name);}
  while(playerHistory.size>512)playerHistory.delete(playerHistory.values().next().value);
$('#connection').textContent=connectionLabel(value.status);$('#connection').className=`pill ${value.status==='connected'?'':'offline'}`;
  if(!current()){selected=value.outputs[0]?.id??null;dirty=false;draft=null;}
  sidebar();
  if(selected){
    const output=current();
    if(!featureBusy&&!saving){
      if(!draft||(!dirty&&revision!==output.revision))select(selected,true);
      else if(dirty&&revision!==output.revision)$('#save-status').textContent='配置已在另一控制页更新';
    }
    updateSelectors();renderHealth();plateControls?.refreshCandidates();
  }else{
    plateControls?.dispose();plateControls=null;
    $('#selected-title').textContent='尚无输出画面';$('#settings').innerHTML='<div class="empty">点击「新建输出」开始</div>';
    $('#preview').src='about:blank';previewUrl='';$('#health').innerHTML='';$('#event-history').innerHTML='';
  }
}
function sidebar(){
  $('#output-count').textContent=`${data.outputs.length} / 12`;
  const markup=data.outputs.map((output,index)=>`<button class="output-item ${output.id===selected?'active':''}" data-output="${output.id}"><span class="item-index">OUTPUT ${String(index+1).padStart(2,'0')}</span><strong>${e(output.config.name)}</strong><small>${layouts[output.config.layout]} · ${Object.values(output.config.features).filter(Boolean).length} 项功能</small></button>`).join('');
  if($('#output-list').innerHTML!==markup)$('#output-list').innerHTML=markup;
}
function select(id,force=false){
  if((featureBusy||saving)&&!force){toast('正在应用更改，请稍候');return;}
  if(dirty&&!force){toast('请先保存当前更改，或点击「取消」');return;}
  selected=id;const output=current();if(!output)return;draft=structuredClone(output.config);revision=output.revision;dirty=false;
  $('#selected-title').textContent=draft.name;$('#revision').textContent=`REV ${revision}`;$('#save-status').textContent='已同步';
  if(previewUrl!==output.url){const u=new URL(output.url,location.href);u.searchParams.set('editor','1');$('#preview').src=u.href;previewUrl=output.url;}
  $('#open-output').href=output.url;renderSettings();sidebar();updateSelectors(true);renderHealth();preview();
}
$('#output-list').addEventListener('click',event=>{const button=event.target.closest('[data-output]');if(button)select(button.dataset.output);});
const field=(label,path,value,type='text',extra='')=>`<label>${label}<input data-field="${path}" type="${type}" value="${e(value)}" ${extra}></label>`;
const toggle=(label,path,value)=>`<label class="toggle"><span>${label}</span><input data-field="${path}" type="checkbox" ${value?'checked':''} aria-label="${label}"></label>`;
const option=(value,label,current)=>`<option value="${e(value)}" ${value===current?'selected':''}>${e(label)}</option>`;
const dropdown=(label,path,choices,current)=>`<label>${label}<select data-field="${path}" aria-label="${label}">${choices.map(([v,l])=>option(v,l,current)).join('')}</select></label>`;
const group=(title,html)=>`<section class="settings-group"><h3>${title}</h3>${html}</section>`;
function renderSettings(){
  plateControls?.dispose();
  const c=draft;
  $('#settings').innerHTML=group('画面与数据源',field('画面名称','name',c.name,'text','maxlength="60"')+
    dropdown('布局','layout',Object.entries(layouts),c.layout)+
    '<label>任务数据源<select id="source-selector" aria-label="任务数据源"></select></label>'+dropdown('单位制','units',[['aviation','航空 · kt / ft'],['metric','公制 · km/h / m']],c.units))+
    group('组件与数据开关','<p class="hint">切换后立即播出并自动保存，仅作用于当前画面。</p>'+Object.entries(session.features).map(([key,label])=>toggle(label,`features.${key}`,c.features[key])).join(''))+
    group('焦点与过滤','<label>焦点飞机<select id="aircraft-selector" aria-label="焦点飞机"></select></label><label>焦点导弹<select id="missile-selector" aria-label="焦点导弹"></select></label>'+dropdown('阵营','filters.coalition',[['all','全部阵营'],['blue','蓝方'],['red','红方'],['neutral','中立']],c.filters.coalition)+toggle('只显示玩家','filters.playersOnly',c.filters.playersOnly)+toggle('只跟踪焦点飞机发射的导弹','filters.missileFocusOnly',c.filters.missileFocusOnly)+field('阵容搜索','filters.search',c.filters.search,'search','placeholder="玩家、单位名或机型" maxlength="64"')+dropdown('阵容排序','filters.sortBy',[['name','名称'],['speed','速度 · 从高到低'],['fuel','油量 · 从高到低'],['altitude','高度 · 从高到低']],c.filters.sortBy))+
    group('赛事信息',field('赛事名称','match.title',c.match.title,'text','maxlength="80"')+field('轮次标签','match.round',c.match.round,'text','maxlength="32"')+`<div class="field-row">${field('左侧队名','match.blueName',c.match.blueName,'text','maxlength="32"')}${field('右侧队名','match.redName',c.match.redName,'text','maxlength="32"')}${field('左侧比分','match.blueScore',c.match.blueScore,'number','min="0" max="999"')}${field('右侧比分','match.redScore',c.match.redScore,'number','min="0" max="999"')}</div><p class="hint">比分由导播手动维护。自定义队伍模式下，这里设置两个选手池的队名。</p>`)+
    group('播报设置',`<div class="field-row">${field('最多条数','eventCount',c.eventCount,'number','min="1" max="12"')}${field('停留秒数','eventDurationSec',c.eventDurationSec,'number','min="3" max="120"')}</div><div class="event-options">${session.eventTypes.map(type=>`<label><input type="checkbox" data-event-type="${type}" ${c.filters.eventTypes.includes(type)?'checked':''}>${e(EVENT_LABELS[type]??type)}</label>`).join('')}</div>`)+
    group('OBS 叠加层外观',toggle('透明背景','appearance.transparent',c.appearance.transparent)+toggle('小地图飞机标签','appearance.labels',c.appearance.labels)+toggle('小地图导弹目标连线','appearance.targetLines',c.appearance.targetLines)+field('安全边距（像素）','appearance.safeMargin',c.appearance.safeMargin,'number','min="0" max="120"')+'<p class="hint">开启透明背景，在 OBS 游戏捕获上方添加 1920×1080「浏览器」源。此处控制网页背景。</p>')+
    group('画面管理','<div class="actions"><button type="button" id="reset" class="outline">还原未保存更改</button><button type="button" id="delete" class="danger">删除画面</button></div>');
  plateControls=mountPlateControls($('#settings'),{getDraft:()=>draft,getState:()=>({...state(),source:source(),connection:data?.status,localStatus:controlLocalStatus,sourcesReceivedAt:data?.sourcesReceivedAt,history:[...playerHistory],players:source()?.hookStatus?.players?.records??[]}),changed,toast,canEdit:()=>session?.user.role!=='viewer'});
  if(session.user.role==='viewer')for(const input of $('#settings').querySelectorAll('input,select,button'))input.disabled=true;
}
function updateSelectors(force=false){
  const sourceSelect=$('#source-selector');if(!sourceSelect||!draft)return;
  const entities=state()?.snapshot?.entities??[];
  const signature=JSON.stringify([data.serverEpoch,data.sources.map(s=>[s.sourceId,s.lifecycle]),entities.map(v=>[v.entityId,entityName(v)]),draft.sourceId,draft.followLatest,draft.aircraftId,draft.missileId]);
  if(!force&&signature===lastSourceSignature)return;lastSourceSignature=signature;
  const chosen=draft.followLatest?'latest':draft.sourceId??'';
  sourceSelect.innerHTML=option('latest','自动跟随最新任务',chosen)+data.sources.map(s=>option(s.sourceId,`任务 #${s.createdOrder} · ${lifecycleLabel(s)}`,chosen)).join('');
  if(!draft.followLatest&&(!data.sources.some(s=>s.sourceId===chosen)||draft.sourceEpoch!==data.serverEpoch))sourceSelect.innerHTML+=option(chosen,'原任务源已不可用，请重新选择',chosen);
  for(const [kind,selector,key,label] of [['aircraft','#aircraft-selector','aircraftId','不指定焦点'],['missile','#missile-selector','missileId','全部导弹']]){
    const choices=entities.filter(v=>v.kind===kind),value=draft[key]??'';
    $(selector).innerHTML=option('',label,value)+choices.map(v=>option(v.entityId,`${entityName(v)} · ${v.identity?.typeName??v.entityId}`,value)).join('');
    if(value&&!choices.some(v=>v.entityId===value))$(selector).innerHTML+=option(value,`${value} · 当前未采集`,value);
  }
}
function cancelPreview(){
  if(!draft||!current()||session?.user.role==='viewer')return;
  if(featureBusy||saving){toast('正在应用更改，请稍候再取消');return;}
  editing=false;editingDetails=false;select(selected,true);toast('已取消未保存更改');
}
$('#cancel-preview').addEventListener('click',cancelPreview);
addEventListener('keydown',ev=>{if(ev.key==='Escape'&&!ev.target.closest('.player-picker'))cancelPreview();});
addEventListener('message',ev=>{if(ev.origin===location.origin&&ev.source===$('#preview').contentWindow&&ev.data?.type==='dcs-cancel-preview')cancelPreview();});
function changed(){plateControls?.refreshNames();dirty=true;$('#save-status').textContent='预览已更新 · 保存后播出';preview();}
function syncFeatureInputs(){
  preview();
  for(const input of $('#settings').querySelectorAll('[data-field^="features."]'))input.checked=draft.features[input.dataset.field.split('.')[1]];
}
async function flushFeatures(){
  if(featureBusy)return;
  featureBusy=true;$('#save').disabled=true;const outputId=selected,owner=session;
  try{
    while(Object.keys(featureQueue).length){
      const patch=featureQueue;featureQueue={};const base=current();
      // Publish only switches, preserving all other unsaved inspector fields.
      if(dirty&&revision!==base.revision)throw new Error('配置已在另一控制页更新，请先还原或处理未保存更改');
      const config=structuredClone(base.config);Object.assign(config.features,patch);
      $('#save-status').textContent='正在应用开关…';
      const saved=await api(`/api/outputs/${outputId}`,{method:'PUT',body:{revision:base.revision,config}});
      if(session!==owner||selected!==outputId)return;
      data.outputs=data.outputs.map(o=>o.id===saved.id&&o.revision<=saved.revision?saved:o);
      revision=saved.revision;draft.features={...saved.config.features,...featureQueue};
      syncFeatureInputs();sidebar();$('#revision').textContent=`REV ${revision}`;
    }
    $('#save-status').textContent=dirty?'开关已实时保存 · 其他更改未保存':'开关已实时保存';
  }catch(error){
    featureQueue={};
    if(session===owner&&selected===outputId&&draft){
      // A failed/conflicting write must not leave the switch claiming success.
      try{data.outputs=await api('/api/outputs');}catch{}
      if(current()){draft.features=structuredClone(current().config.features);if(!dirty)revision=current().revision;syncFeatureInputs();}
      toast(error.message);$('#save-status').textContent='开关应用失败 · 已恢复当前设置';
    }
  }finally{
    featureBusy=false;$('#save').disabled=!session||session.user.role==='viewer';
    if(session===owner&&draft&&!dirty&&current()&&revision!==current().revision)select(selected,true);
  }
}
$('#settings').addEventListener('input',event=>{
  const input=event.target,path=input.dataset.field;if(!draft)return;
  if(path?.startsWith('features.')){
    if(saving||session.user.role==='viewer'){syncFeatureInputs();return;}
    const key=path.split('.')[1];draft.features[key]=input.checked;featureQueue[key]=input.checked;void flushFeatures();return;
  }
  if(path){const parts=path.split('.');let target=draft;for(const key of parts.slice(0,-1))target=target[key];target[parts.at(-1)]=input.type==='checkbox'?input.checked:input.type==='number'?Number(input.value):input.value;changed();}
  if(input.dataset.eventType){draft.filters.eventTypes=[...$('#settings').querySelectorAll('[data-event-type]:checked')].map(el=>el.dataset.eventType);changed();}
});
$('#settings').addEventListener('change',async event=>{
  if(!draft)return;
  if(event.target.id==='source-selector'){draft.followLatest=event.target.value==='latest';draft.sourceId=draft.followLatest?null:event.target.value;draft.sourceEpoch=draft.followLatest?null:data.serverEpoch;draft.aircraftId=null;draft.missileId=null;changed();updateSelectors(true);}
  if(event.target.id==='aircraft-selector'){draft.aircraftId=event.target.value||null;changed();}
  if(event.target.id==='missile-selector'){draft.missileId=event.target.value||null;changed();}
});
$('#settings').addEventListener('click',async event=>{
  if((featureBusy||saving)&&['reset','delete'].includes(event.target.id)){toast('正在应用更改，请稍候');return;}
  if(event.target.id==='reset')cancelPreview();
  if(event.target.id==='delete'){
    try{await api(`/api/outputs/${selected}`,{method:'DELETE',body:{revision}});dirty=false;draft=null;toast('画面已删除');}catch(error){toast(error.message);}
  }
});
$('#settings-form').addEventListener('submit',async event=>{
  event.preventDefault();if(!draft||featureBusy||saving)return;saving=true;$('#save').disabled=true;
  try{const saved=await api(`/api/outputs/${selected}`,{method:'PUT',body:{revision,config:draft}});data.outputs=data.outputs.map(o=>o.id===saved.id?saved:o);dirty=false;select(saved.id,true);toast('已保存并更新播出画面');}
  catch(error){toast(error.message);$('#save-status').textContent='保存失败 · 更改仍保留';}
  finally{saving=false;$('#save').disabled=!session||session.user.role==='viewer';}
});
async function create(config){if(featureBusy||saving){toast('正在应用更改，请稍候');return;}if(dirty){toast('请先保存当前画面更改');return;}try{const output=await api('/api/outputs',{method:'POST',body:{config}});data.outputs=data.outputs.filter(o=>o.id!==output.id);data.outputs.push(output);select(output.id,true);toast('新输出已创建');}catch(error){toast(error.message);}}
$('#new-output').addEventListener('click',()=>create(structuredClone(session.defaultConfig)));
$('#duplicate').addEventListener('click',()=>{if(draft){const config=structuredClone(draft);config.name=config.name.slice(0,55)+' 副本';create(config);}});
$('#copy-url').addEventListener('click',async()=>{if(!current())return;try{await navigator.clipboard.writeText(current().url);toast('已复制 OBS 浏览器源地址');}catch{toast('复制受浏览器限制，可从「打开输出」页面复制地址');}});
function renderHealth(){
  const s=source(),snapshot=state()?.snapshot;
  const fresh=s?.snapshotFresh&&data.status==='connected'&&Date.now()-(data.sourcesReceivedAt??data.serverTime)<3000;
  const capture=s?.captureIntegrity==='complete_since_capture_start'?'自采集开始连续':s?.captureIntegrity==='incomplete'?'采集存在缺失':'采集完整性未知';
  const transport=s?.transportComplete?'结束事件已收齐':s?.lifecycle==='ended'?'结束传输不完整':'等待任务结束后确认';
  const retained=s?.historyRetained===false?'部分历史已释放':s?'历史仍保留':'等待数据';
  $('#health').innerHTML=`<div class="health-card"><small>任务与快照</small><strong>${e(lifecycleLabel(s))}</strong><p class="hint">${fresh?'数据新鲜':s?.lifecycle==='ended'?'显示历史快照':'等待更新'} · ${snapshot?.entities?.length??'—'} 个对象</p></div><div class="health-card"><small>采集与传输</small><strong>${e(capture)}</strong><p class="hint">${e(transport)}</p></div><div class="health-card"><small>事件与历史</small><strong>${s?.receivedThrough??'—'} 条已确认序号</strong><p class="hint">${e(retained)}${s?.collectorAck?.state==='unverified'?' · 任务环境清理未验证':''}</p></div>`;
  const events=(state()?.events??[]).slice(-12).reverse();
  $('#event-history').innerHTML=events.length?events.map(event=>`<div class="history-row"><time>${missionTime(event.simTime)}</time><span>${e(eventText(event))}</span><small class="muted">#${event.eventSeq}${event.historical?' · 历史':''}</small></div>`).join(''):'<div class="empty">等待任务事件</div>';
}
enter().catch(()=>showLogin());
