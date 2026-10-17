import {mountPlayerPicker,playerDirectory} from './player-picker.mjs';
import {escape as e} from './stream.mjs';
import {PLATE_FIELDS,DOCK_PARTS,ANCHORS,newOverride,plateSettings} from './nameplates.mjs';

export function mountPlateControls(container,{getDraft,getState,changed,toast,canEdit}){
  const root=document.createElement('section');root.className='settings-group plate-controls';container.append(root);
  let target='template',dockTarget='blue';
  function addPlayer(name,side){
    if(!canEdit()||!['blue','red'].includes(side))return;
    name=name.trim();const p=getDraft().nameplates;
    if(!name||name.length>128){toast('请输入不超过 128 字的选手名称');return;}
    const existing=p.fixedSlots.find(s=>s.binding==='player'&&s.playerName===name);
    if(existing){if(existing.team===side){toast('该选手已经在此池内');return;}existing.team=side;}
    else {if(p.fixedSlots.length>=32){toast('最多 32 个席位');return;}p.fixedSlots.push({id:crypto.randomUUID(),label:name.slice(0,60),binding:'player',playerName:name,unitName:'',team:side,dock:null});}
    changed();render();picker.refresh();
  }
  const picker=mountPlayerPicker({getState,getDraft,addPlayer,canEdit});
  root.addEventListener('dragover',ev=>{const pool=ev.target.closest('[data-pool-side]');if(pool&&canEdit()&&ev.dataTransfer.types.includes('application/x-dcs-player')){ev.preventDefault();ev.dataTransfer.dropEffect='copy';pool.classList.add('drop-ready');}});
  root.addEventListener('dragleave',ev=>{const pool=ev.target.closest('[data-pool-side]');if(pool&&!pool.contains(ev.relatedTarget))pool.classList.remove('drop-ready');});
  root.addEventListener('drop',ev=>{const pool=ev.target.closest('[data-pool-side]');if(!pool)return;pool.classList.remove('drop-ready');const name=ev.dataTransfer.getData('application/x-dcs-player');if(!name)return;ev.preventDefault();if(playerDirectory(getState()).some(r=>r.name===name))addPlayer(name,pool.dataset.poolSide);});
  const opt=(v,label,value)=>`<option value="${e(v)}" ${v===value?'selected':''}>${e(label)}</option>`;
  const select=(label,key,choices,value)=>`<label>${label}<select data-p="${key}">${choices.map(([v,l])=>opt(v,l,value)).join('')}</select></label>`;
  const field=(label,key,value,type='text',extra='')=>`<label>${label}<input data-p="${key}" type="${type}" value="${e(value??'')}" ${extra}></label>`;
  const check=(label,key,value)=>`<label class="toggle"><span>${label}</span><input type="checkbox" data-p="${key}" ${value?'checked':''}></label>`;
  function override(){const p=getDraft().nameplates;let o=p.overrides.find(o=>o.unitName===target);if(!o){o=newOverride(target);p.overrides.push(o);}return o;}
  function dockObject(){const c=getDraft();if(dockTarget.startsWith('slot:'))return c.nameplates.fixedSlots.find(s=>s.id===dockTarget.slice(5));if(dockTarget.startsWith('plate:')){const name=dockTarget.slice(6);let o=c.nameplates.overrides.find(o=>o.unitName===name);if(!o){o=newOverride(name);c.nameplates.overrides.push(o);}return o;}return null;}
  function getDock(){const c=getDraft();if(dockTarget.startsWith('slot:'))return c.nameplates.fixedSlots.find(s=>s.id===dockTarget.slice(5))?.dock;if(dockTarget.startsWith('plate:'))return c.nameplates.overrides.find(s=>s.unitName===dockTarget.slice(6))?.dock;return c.docks[dockTarget];}
  function setDock(dock){const o=dockObject();if(o)o.dock=dock;else getDraft().docks[dockTarget]=dock;}
  function render(){
    const c=getDraft(),p=c.nameplates,entities=getState()?.snapshot?.entities??[],slots=p.fixedSlots;
    const names=[...new Set([...entities.filter(e=>e.kind==='aircraft').map(e=>e.identity?.unitName),...p.overrides.filter(o=>!o.unitName.startsWith('player:')).map(o=>o.unitName)].filter(Boolean))];
    const players=[...new Set([...entities.map(e=>e.occupancy?.playerName),...(getState()?.players??[]).map(r=>r.name),...slots.map(s=>s.playerName)].filter(Boolean))];
    const targets=[['template','统一模板'],...players.map(n=>['player:'+n,'选手 · '+n]),...names.map(n=>[n,'飞机 · '+n])];
    if(!targets.some(([v])=>v===target))target='template';
    const settings=target==='template'?p:plateSettings(c,target.startsWith('player:')?null:target,target.startsWith('player:')?target.slice(7):null);
    const dockChoices=[...Object.entries(DOCK_PARTS),...slots.map(s=>['slot:'+s.id,'席位 · '+(s.playerName||s.unitName||s.label)]),...names.map(n=>['plate:'+n,'标牌 · '+n])];
    if(!dockChoices.some(([v])=>v===dockTarget))dockTarget='blue';const dock=getDock();
    root.innerHTML=`<h3>分队与选手池</h3><button type="button" data-open-picker>打开在线 / 历史选手小窗</button>${select('分队模式','mode',[['coalition','DCS 红蓝阵营'],['teams','自定义队伍']],c.competition.mode)}
      <p class="hint">${c.competition.mode==='teams'?'按手动选手池归属显示，不读取红蓝阵营。可在各选手池直接修改队名和颜色，比分在赛事信息中设置。':'选手池自动识别红蓝方；未知阵营暂列左侧。未入池飞机仍按筛选显示。'}</p>
      ${['blue','red'].map((side,i)=>`<div class="pool-box" data-pool-side="${side}"><strong data-pool-title="${side}">${e(c.match[side+'Name'])} · ${i?'队伍二 / 右侧':'队伍一 / 左侧'}</strong>${field(i?'队伍二名称':'队伍一名称','teamName.'+side,c.match[side+'Name'],'text','maxlength="32"')}${c.competition.mode==='teams'?field(i?'队伍二颜色':'队伍一颜色','teamColor.'+side,c.competition[side+'Color']??(side==='blue'?'#56bbfa':'#ff6970'),'color'):''}<label>上传${i?'右':'左'}队队标<input type="file" data-logo="${side}" accept="image/png,image/jpeg,image/webp"></label>${c.competition[side+'Logo']?`<img class="logo-preview" src="${e(c.competition[side+'Logo'])}" alt="队标"><button type="button" data-clear-logo="${side}">移除队标</button>`:''}<div class="field-row"><label>选手名称<input data-add-name="${side}" list="pool-candidates" placeholder="输入或选择 DCS 玩家名称"></label><button type="button" data-add-player="${side}">加入选手池</button></div>${slots.filter(s=>s.binding==='player'&&s.team===side).map(s=>`<div class="pool-row"><span>${e(s.playerName)}</span><button type="button" data-edit-slot="${s.id}">Dock</button><button type="button" data-swap="${s.id}">换队</button><button type="button" data-remove="${s.id}">移除</button></div>`).join('')}</div>`).join('')}
      <datalist id="pool-candidates">${players.map(n=>`<option value="${e(n)}"></option>`).join('')}</datalist>
      <p class="hint">按玩家名称精确绑定；重进飞机自动跟随。同名冲突显示待确认。只有 DCS 选手断线判死，数据链路中断不判死。</p>
      <h3>标牌数量与筛选</h3><div class="field-row">${field('左侧同时显示','blueCount',p.blueCount,'number','min="0" max="16"')}${field('右侧同时显示','redCount',p.redCount,'number','min="0" max="16"')}</div>${check('固定标牌数量（不足时保留空位）','fixedCount',p.fixedCount)}${check('自动轮换超出数量的标牌','rotate',p.rotate)}${field('轮换间隔（秒）','rotationSec',p.rotationSec,'number','min="3" max="120"')}
      ${select('身份筛选','filter.occupancy',[['all','全部'],['player','玩家'],['ai','AI'],['unknown','未知']],p.filters.occupancy)}${field('机型包含','filter.type',p.filters.type)}${field('武器包含','filter.weapon',p.filters.weapon)}
      ${[['fuel','油量 %'],['speed','速度 km/h'],['altitude','高度 m']].map(([k,l])=>`<div class="field-row">${field(l+' 下限','filter.'+k+'Min',p.filters[k+'Min'],'number')}${field(l+' 上限','filter.'+k+'Max',p.filters[k+'Max'],'number')}</div>`).join('')}
      <p class="hint">空白表示不限制。固定 Dock 不受分页和筛选影响；池内死亡席位保留，不以过期油量、速度筛除。</p>
      <h3>每张标牌的信息与大小</h3>${select('编辑标牌','target',targets,target)}${Object.entries(PLATE_FIELDS).map(([k,l])=>check('标牌 · '+l,'field.'+k,settings.fields[k])).join('')}
      <div class="field-row">${field('标牌宽度','width',settings.width,'number','min="240" max="520"')}${field('标牌缩放 %','scale',settings.scale,'number','min="50" max="150"')}</div>${target!=='template'?check('显示此标牌','visible',settings.visible)+`<button type="button" data-inherit>恢复统一模板</button>`:''}
      <h3>固定席位与自由 Dock</h3><p class="hint">开启预览编辑后，拖动标签移动、拖动右下角缩放；按住 Shift 取消吸附。可切换到内部元素，单独调整文字、比分、数据条等。拖入固定席位可绑定飞机。所有位置按 1920×1080 保存。</p>
      <button type="button" data-edit-preview>切换预览拖动</button><button type="button" data-edit-details>整体组件 / 内部元素</button><button type="button" data-reset-elements>恢复所有元素尺寸与内部位置</button><button type="button" data-add-slot>＋ 固定飞机席位</button>
      ${select('Dock 对象','dockTarget',dockChoices,dockTarget)}${select('吸附基准','anchor',Object.entries(ANCHORS),dock?.anchor??'top-left')}<div class="field-row">${field('横向偏移','dockX',dock?.x??0,'number')}${field('纵向偏移','dockY',dock?.y??0,'number')}</div><button type="button" data-reset-dock>恢复自动位置</button>
      ${dockTarget.startsWith('slot:')?slotEditor(slots.find(s=>s.id===dockTarget.slice(5)),names):''}`;
    if(!canEdit())for(const el of root.querySelectorAll('input,select,button'))el.disabled=true;
  }
  function slotEditor(s,names){return `<p class="hint">固定席位：${e(s.label)}</p>${s.binding==='unit'?select('绑定飞机','slotUnit',[['','未绑定'],...names.map(n=>[n,n])],s.unitName):''}<button type="button" data-remove="${s.id}">删除此席位</button>`;}
  root.addEventListener('input',ev=>{
    const key=ev.target.dataset.p;if(!key||!canEdit())return;ev.stopPropagation();const c=getDraft(),p=c.nameplates,v=ev.target.type==='checkbox'?ev.target.checked:ev.target.type==='number'?(ev.target.value===''?null:Number(ev.target.value)):ev.target.value;
    if(key==='target'){target=v;render();return;}if(key==='dockTarget'){dockTarget=v;render();return;}
    if(key==='mode'){c.competition.mode=v;changed();render();return;}
    if(key.startsWith('teamName.')){const side=key.slice(9);c.match[side+'Name']=v;const input=container.querySelector(`[data-field="match.${side}Name"]`);if(input)input.value=v;refreshNames();}
    else if(key.startsWith('teamColor.'))c.competition[key.slice(10)+'Color']=v;
    else if(key.startsWith('filter.'))p.filters[key.slice(7)]=v;
    else if(key.startsWith('field.'))(target==='template'?p:override()).fields[key.slice(6)]=v;
    else if(['width','scale','visible'].includes(key))(target==='template'?p:override())[key]=v;
    else if(['anchor','dockX','dockY'].includes(key)){const d=getDock()??{anchor:'top-left',x:32,y:320};d[key==='dockX'?'x':key==='dockY'?'y':'anchor']=v;setDock(d);}
    else if(key==='slotUnit')dockObject().unitName=v;
    else p[key]=v;
    changed();
  });
  root.addEventListener('click',ev=>{
    const b=ev.target.closest('button');if(!b||!canEdit())return;const c=getDraft(),p=c.nameplates;
    if(b.hasAttribute('data-edit-details')){dispatchEvent(new CustomEvent('toggle-element-details'));return;}
    if(b.hasAttribute('data-reset-elements')){c.elementLayouts={};changed();return;}
    if(b.hasAttribute('data-edit-preview')){dispatchEvent(new CustomEvent('toggle-dock-editor'));return;}
    if(b.dataset.editSlot){dockTarget='slot:'+b.dataset.editSlot;render();return;}
    if(b.hasAttribute('data-open-picker')){picker.open();return;}
    if(b.dataset.addPlayer){addPlayer(root.querySelector(`[data-add-name="${b.dataset.addPlayer}"]`).value,b.dataset.addPlayer);return;}
    else if(b.hasAttribute('data-add-slot')){if(p.fixedSlots.length>=32){toast('最多 32 个席位');return;}const s={id:crypto.randomUUID(),label:'固定飞机席位',binding:'unit',unitName:'',playerName:'',team:'blue',dock:{anchor:'top-left',x:400,y:320}};p.fixedSlots.push(s);dockTarget='slot:'+s.id;}
    else if(b.dataset.remove)p.fixedSlots=p.fixedSlots.filter(s=>s.id!==b.dataset.remove);
    else if(b.dataset.swap){const s=p.fixedSlots.find(s=>s.id===b.dataset.swap);s.team=s.team==='blue'?'red':'blue';}
    else if(b.dataset.clearLogo)c.competition[b.dataset.clearLogo+'Logo']='';
    else if(b.hasAttribute('data-reset-dock')){if(dockObject()?.binding==='unit'){toast('固定飞机席位需保留位置，可删除席位解除绑定');return;}setDock(null);}
    else if(b.hasAttribute('data-inherit'))p.overrides=p.overrides.filter(o=>o.unitName!==target);
    else return;changed();render();
  });
  root.addEventListener('change',async ev=>{
    const side=ev.target.dataset.logo,file=ev.target.files?.[0];if(!side||!file||!canEdit())return;
    const owner=getDraft();try{
      if(!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size>5*1024*1024)throw new Error('请选择 5 MB 以内的 PNG、JPEG 或 WebP 图片');
      const bitmap=await createImageBitmap(file),canvas=document.createElement('canvas');let url='';
      try{for(let edge=1024;edge>=128;edge=Math.floor(edge*.75)){
        const scale=Math.min(1,edge/Math.max(bitmap.width,bitmap.height));canvas.width=Math.max(1,Math.round(bitmap.width*scale));canvas.height=Math.max(1,Math.round(bitmap.height*scale));canvas.getContext('2d').drawImage(bitmap,0,0,canvas.width,canvas.height);
        url=canvas.toDataURL('image/png');if(url.length>100000)url=canvas.toDataURL('image/webp',.85);if(url.length<=100000)break;
      }}finally{bitmap.close();}
      if(url.length>100000)throw new Error('队标压缩后仍过大，请换用较简单的图片');
      if(owner!==getDraft())return;owner.competition[side+'Logo']=url;changed();render();
    }catch(error){toast(error.message);}
  });
  function refreshCandidates(){
    picker.refresh();
    const c=getDraft(),state=getState(),entities=state?.snapshot?.entities??[];
    const names=[...new Set(entities.filter(e=>e.kind==='aircraft').map(e=>e.identity?.unitName).filter(Boolean))];
    const players=[...new Set([...entities.map(e=>e.occupancy?.playerName),...(state?.players??[]).map(r=>r.name)].filter(Boolean))];
    for(const [selector,items] of [['[data-p="target"]',[...players.map(n=>['player:'+n,'选手 · '+n]),...names.map(n=>[n,'飞机 · '+n])]],['[data-p="dockTarget"]',names.map(n=>['plate:'+n,'标牌 · '+n])],['[data-p="slotUnit"]',names.map(n=>[n,n])]]){
      const el=root.querySelector(selector);if(!el)continue;const existing=new Set([...el.options].map(o=>o.value));for(const [value,label] of items)if(!existing.has(value))el.add(new Option(label,value));
    }
    const list=root.querySelector('#pool-candidates');if(list){const existing=new Set([...list.options].map(o=>o.value));for(const player of players)if(!existing.has(player)){const o=document.createElement('option');o.value=player;list.append(o);}}
  }
  function refreshNames(){
    for(const [i,side] of ['blue','red'].entries()){
      const name=getDraft().match[side+'Name'],input=root.querySelector(`[data-p="teamName.${side}"]`),title=root.querySelector(`[data-pool-title="${side}"]`);
      if(input&&input.value!==name)input.value=name;if(title)title.textContent=name+' · '+(i?'队伍二 / 右侧':'队伍一 / 左侧');
    }
  }
  render();return {render,refreshCandidates,refreshNames,dispose:()=>picker.dispose()};
}
