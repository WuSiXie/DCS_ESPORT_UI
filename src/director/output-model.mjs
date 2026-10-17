import { randomUUID, randomBytes } from 'node:crypto';
import { defaultPlates, PLATE_FIELDS, DOCK_PARTS, ANCHORS } from '../web/nameplates.mjs';

export const FEATURES = Object.freeze({
  match: '比赛信息', map: '战术小地图', roster: '两侧选手卡',
  missiles: '导弹追踪', events: '事件播报', status: '链路状态',
  mapMissileName: '小地图 · 导弹名称', mapMissileLauncher: '小地图 · 发射人', incoming: '标牌 · 来袭导弹图标', incomingName: '来袭导弹 · 名称', incomingLauncher: '来袭导弹 · 发射人',
  teamLogos: '队标', fuel: '油量条与数值', speed: '飞行速度', altitude: '海拔高度', loadout: '武器挂载',
});
export const EVENT_TYPES = Object.freeze([
  'weapon_fired', 'hit', 'kill', 'crash', 'dead', 'unit_lost', 'ejection', 'pilot_dead',
  'takeoff', 'land', 'entity_born', 'entity_removed', 'player_entered', 'player_left',
  'weapon_track_ended', 'target_observation_changed', 'capture_record_rejected',
]);
export const LAYOUTS = Object.freeze(['overview', 'tactical']);
export class ValidationError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}
const fail = message => { throw new ValidationError(message); };
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = (value, name, length) => {
  if (typeof value !== 'string' || value.length > length || /[\u0000-\u001f]/u.test(value)) fail(`${name}格式不正确`);
  return value;
};
const choice = (value, values, name) => { if (!values.includes(value)) fail(`${name}不受支持`); return value; };
const integer = (value, min, max, name) => {
  if (!Number.isInteger(value) || value < min || value > max) fail(`${name}必须在 ${min}～${max} 之间`);
  return value;
};
const bool = (value, name) => { if (typeof value !== 'boolean') fail(`${name}必须为开关值`); return value; };
const nullableId = (value, name) => value === null ? null : text(value, name, 256);

export function defaultConfig(layout = 'overview') {
  choice(layout, LAYOUTS, '布局');
  return {
    name: { overview: '比赛直播', tactical: '紧凑阵容' }[layout],
    layout, sourceId: null, sourceEpoch: null, followLatest: true, aircraftId: null, missileId: null,
    features: Object.fromEntries(Object.keys(FEATURES).map(key => [key, true])),
    competition:{mode:'coalition',blueLogo:'',redLogo:'',blueColor:'#56bbfa',redColor:'#ff6970'},
    match: { title: 'DCS 空战竞技', blueName: '蓝方', redName: '红方', blueScore: 0, redScore: 0, round: 'LIVE' },
    filters: { coalition: 'all', playersOnly: false, missileFocusOnly: false, search: '', sortBy: 'name', eventTypes: [...EVENT_TYPES] },
    appearance: { transparent: true, safeMargin: 32, labels: true, targetLines: true },
    nameplates:defaultPlates(layout),docks:Object.fromEntries(Object.keys(DOCK_PARTS).map(k=>[k,null])),elementLayouts:{},
    units: 'aviation', eventCount: 5, eventDurationSec: 12,
  };
}

// Reconstruct the known schema; no arbitrary HTML, CSS, paths or prototype keys
// survive validation. Every setting is scoped to this output's configuration.
export function migrateRetiredFeatures(input){
  const config=structuredClone(input);delete config.followCamera;
  if(config.layout==='focus'){config.layout='overview';if(config.name==='选手特写')config.name='比赛直播';}
  if(config.features)delete config.features.aircraft;
  if(config.docks)delete config.docks.aircraft;
  if(config.elementLayouts)for(const key of Object.keys(config.elementLayouts))if(key==='aircraft'||key.startsWith('aircraft/'))delete config.elementLayouts[key];
  return config;
}
export function validateConfig(input) {
  if (!object(input)) fail('画面配置必须是对象');
  const template = defaultConfig();
  for (const key of Object.keys(input)) if (!Object.hasOwn(template, key)) fail(`未知设置：${key}`);
  const result = {};
  result.name = text(input.name, '画面名称', 60).trim(); if (!result.name) fail('画面名称不能为空');
  result.layout = choice(input.layout, LAYOUTS, '布局');
  result.sourceId = nullableId(input.sourceId, '任务源');
  result.sourceEpoch = nullableId(input.sourceEpoch ?? null, '任务源所属服务器会话');
  result.followLatest = bool(input.followLatest, '自动跟随任务');
  result.aircraftId = nullableId(input.aircraftId, '焦点飞机');
  result.missileId = nullableId(input.missileId, '焦点导弹');
  if (!object(input.features)) fail('功能开关不完整');
  result.features = {};
  for (const key of Object.keys(input.features)) if (!Object.hasOwn(FEATURES, key)) fail(`未知功能：${key}`);
  // Older profiles have seven switches. New metric switches default on without
  // changing any existing choice or accepting a missing legacy feature block.
  for (const key of Object.keys(FEATURES)) result.features[key] = bool(
    Object.hasOwn(input.features,key) ? input.features[key] : (['fuel','speed','altitude','loadout','teamLogos','mapMissileName','mapMissileLauncher','incoming','incomingName','incomingLauncher'].includes(key) ? true : undefined), FEATURES[key]);
  if (!object(input.match) || !object(input.filters) || !object(input.appearance)) fail('配置区块不完整');
  result.match = {
    title: text(input.match.title, '赛事名称', 80), blueName: text(input.match.blueName, '蓝方队名', 32),
    redName: text(input.match.redName, '红方队名', 32), round: text(input.match.round, '轮次', 32),
    blueScore: integer(input.match.blueScore, 0, 999, '蓝方比分'), redScore: integer(input.match.redScore, 0, 999, '红方比分'),
  };
  const competition=input.competition??template.competition;
  keys(competition,['mode','blueLogo','redLogo','blueColor','redColor'],'队伍设置');
  result.competition={mode:choice(competition.mode,['coalition','teams'],'分队模式'),blueLogo:logo(competition.blueLogo),redLogo:logo(competition.redLogo)};
  for(const side of ['blue','red']){
    const key=side+'Color',value=Object.hasOwn(competition,key)?competition[key]:template.competition[key];
    if(typeof value!=='string'||!/^#[0-9a-f]{6}$/iu.test(value))fail('队伍颜色必须为 #RRGGBB 格式');
    result.competition[key]=value.toLowerCase();
  }
  const types = input.filters.eventTypes;
  if (!Array.isArray(types) || types.length > EVENT_TYPES.length || types.some(t => !EVENT_TYPES.includes(t))) fail('事件过滤不正确');
  result.filters = {
    coalition: choice(input.filters.coalition, ['all', 'blue', 'red', 'neutral'], '阵营'),
    playersOnly: bool(input.filters.playersOnly, '只显示玩家'),
    missileFocusOnly: bool(input.filters.missileFocusOnly, '仅焦点飞机导弹'), eventTypes: [...new Set(types)],
    search: text(input.filters.search ?? '', '阵容搜索', 64),
    sortBy: choice(input.filters.sortBy ?? 'name', ['name', 'speed', 'fuel', 'altitude'], '阵容排序'),
  };
  result.appearance = {
    transparent: bool(input.appearance.transparent, '透明背景'),
    safeMargin: integer(input.appearance.safeMargin, 0, 120, '安全边距'),
    labels: bool(input.appearance.labels, '对象标签'), targetLines: bool(input.appearance.targetLines, '目标连线'),
  };
  result.units = choice(input.units, ['aviation', 'metric'], '单位制');
  result.eventCount = integer(input.eventCount, 1, 12, '事件条数');
  result.eventDurationSec = integer(input.eventDurationSec, 3, 120, '播报停留秒数');
  result.nameplates=validatePlates(Object.hasOwn(input,'nameplates')?input.nameplates:defaultPlates(result.layout));
  const docks=Object.hasOwn(input,'docks')?input.docks:template.docks;keys(docks,Object.keys(DOCK_PARTS),'Dock');
  result.docks=Object.fromEntries(Object.keys(DOCK_PARTS).map(k=>[k,validateDock(docks[k]??null)]));
  const elements=Object.hasOwn(input,'elementLayouts')?input.elementLayouts:{};if(!object(elements)||Object.keys(elements).length>1024)fail('元素布局最多保存 1024 项');
  result.elementLayouts=Object.fromEntries(Object.entries(elements).map(([key,v])=>{
    if(key.length>600||/[\u0000-\u001f]/u.test(key)||!Object.keys(DOCK_PARTS).some(k=>key===k||key.startsWith(k+'/'))&&!/^(plate:|slot:).+/u.test(key))fail('元素布局名称不正确');
    keys(v,['dx','dy','scaleX','scaleY'],'元素布局');
    const result={dx:integer(v.dx,-3840,3840,'元素横向偏移'),dy:integer(v.dy,-2160,2160,'元素纵向偏移')};
    for(const dimension of ['scaleX','scaleY']){const n=v[dimension];if(typeof n!=='number'||!Number.isFinite(n)||n<.1||n>8)fail('元素缩放必须在 0.1～8 之间');result[dimension]=n;}
    return [key,result];
  }));
  return result;
}

function logo(value){
  if(value==='')return value;
  if(typeof value!=='string'||value.length>100000||!/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$/u.test(value))fail('队标必须为不超过 75 KB 的 PNG、JPEG 或 WebP 图片');
  return value;
}
function keys(value,allowed,name){if(!object(value)||Object.keys(value).some(k=>!allowed.includes(k)))fail(`${name}字段不正确`);}
function validateDock(value){
  if(value===null)return null;keys(value,['anchor','x','y'],'Dock');
  return {anchor:choice(value.anchor,Object.keys(ANCHORS),'吸附位置'),x:integer(value.x,-1920,1920,'横向偏移'),y:integer(value.y,-1080,1080,'纵向偏移')};
}
function fields(value,partial=false){
  keys(value,Object.keys(PLATE_FIELDS),'标牌信息');
  return Object.fromEntries((partial?Object.keys(value):Object.keys(PLATE_FIELDS)).map(k=>[k,bool(value[k],PLATE_FIELDS[k])]));
}
function validatePlates(p){
  const defaults=defaultPlates();keys(p,Object.keys(defaults),'标牌');
  keys(p.filters,Object.keys(defaults.filters),'标牌筛选');
  const f={occupancy:choice(p.filters.occupancy,['all','player','ai','unknown'],'标牌身份'),type:text(p.filters.type,'机型筛选',80),weapon:text(p.filters.weapon,'武器筛选',80)};
  for(const key of ['fuel','speed','altitude']){
    for(const suffix of ['Min','Max']){
      const n=p.filters[key+suffix];if(n!==null&&(typeof n!=='number'||!Number.isFinite(n)||n<(key==='altitude'?-2000:0)||n>1000000))fail('标牌数值筛选不正确');f[key+suffix]=n;
    }
    if(f[key+'Min']!==null&&f[key+'Max']!==null&&f[key+'Min']>f[key+'Max'])fail('筛选最小值不能大于最大值');
  }
  if(!Array.isArray(p.overrides)||p.overrides.length>256)fail('最多保存 256 张单独标牌设置');
  const names=new Set();const overrides=p.overrides.map(o=>{
    keys(o,['unitName','visible','fields','width','scale','dock'],'单张标牌');const unitName=text(o.unitName,'单位名称',256);if(!unitName||names.has(unitName))fail('单位名称为空或重复');names.add(unitName);
    return {unitName,visible:bool(o.visible,'显示此标牌'),fields:fields(o.fields,true),width:o.width===null?null:integer(o.width,240,520,'标牌宽度'),scale:o.scale===null?null:integer(o.scale,50,150,'标牌缩放'),dock:validateDock(o.dock)};
  });
  if(!Array.isArray(p.fixedSlots)||p.fixedSlots.length>32)fail('最多 32 个固定席位');
  const ids=new Set(),bindings=new Set();const fixedSlots=p.fixedSlots.map(s=>{
    keys(s,['id','label','binding','unitName','playerName','team','dock'],'固定席位');const id=text(s.id,'席位 ID',36);if(!/^[a-f0-9-]{36}$/u.test(id)||ids.has(id))fail('固定席位 ID 不正确');ids.add(id);
    const binding=choice(s.binding??'unit',['unit','player'],'绑定方式'),unitName=text(s.unitName??'','席位绑定飞机',256),playerName=text(s.playerName??'','选手名称',128).trim();
    if(binding==='player'&&!playerName)fail('选手名称不能为空');
    const key=binding+':'+(binding==='player'?playerName:unitName);if(key!== 'unit:'&&bindings.has(key))fail('同一对象不能重复加入选手池或固定席位');bindings.add(key);
    const dock=validateDock(s.dock);if(binding==='unit'&&!dock)fail('飞机固定席位必须设置位置');
    return {id,label:text(s.label,'席位名称',60),binding,unitName,playerName,team:choice(s.team??'blue',['blue','red'],'所属队伍'),dock};
  });
  return {fields:fields(p.fields),width:integer(p.width,240,520,'默认标牌宽度'),scale:integer(p.scale,50,150,'默认标牌缩放'),blueCount:integer(p.blueCount,0,16,'蓝方标牌数量'),redCount:integer(p.redCount,0,16,'红方标牌数量'),fixedCount:bool(Object.hasOwn(p,'fixedCount')?p.fixedCount:false,'固定标牌数量'),rotate:bool(p.rotate,'轮换标牌'),rotationSec:integer(p.rotationSec,3,120,'轮换间隔'),filters:f,overrides,fixedSlots};
}

export function newOutput(layout = 'overview', config) {
  return { id: randomUUID(), revision: 1, readKey: randomBytes(32).toString('hex'),
    config: validateConfig(config ?? defaultConfig(layout)) };
}
export function publicOutput(output) {
  return { id: output.id, revision: output.revision, config: structuredClone(output.config) };
}
