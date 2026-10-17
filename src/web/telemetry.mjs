export const EVENT_LABELS = Object.freeze({
  entity_born: '进入战场', entity_removed: '移出跟踪', weapon_fired: '导弹发射', hit: '命中事件',
  kill: '击杀事件', crash: '坠毁', dead: '死亡事件', unit_lost: '单位损失', ejection: '弹射',
  pilot_dead: '飞行员死亡', takeoff: '起飞', land: '着陆', player_entered: '玩家进入',
  player_left: '玩家离开', weapon_track_ended: '导弹跟踪结束', target_observation_changed: '目标观察变化',
  capture_record_rejected: '采集记录不完整',
});
export const finite = value => typeof value === 'number' && Number.isFinite(value);
const named = value => typeof value === 'string' && value.length > 0;
export function entityName(entity) {
  if (!entity) return '未知对象';
  if (entity.occupancy?.isPlayer === true && named(entity.occupancy.playerName)) return entity.occupancy.playerName;
  if (entity.isPlayer === true && named(entity.playerName)) return entity.playerName;
  return entity.identity?.unitName || entity.name || entity.identity?.typeName || entity.typeName || entity.entityId || '未知对象';
}
export function coalition(entity) { return entity?.identity?.coalition ?? entity?.coalition ?? 'unknown'; }
export function measurement(value, status, unit, factor = 1, digits = 0) {
  const known = finite(value);
  return { value: known ? value * factor : null, text: known ? (value * factor).toFixed(digits) : '—',
    unit, quality: known ? (status ?? 'unknown') : 'unavailable', stale: status === 'stale' };
}
export function speed(entity, units = 'aviation') {
  return measurement(entity?.motion?.speedMps, entity?.motion?.status, units === 'aviation' ? 'kt' : 'km/h', units === 'aviation' ? 1.94384449244 : 3.6);
}
export function altitude(entity, units = 'aviation') {
  return measurement(entity?.motion?.position?.y, entity?.motion?.status, units === 'aviation' ? 'ft' : 'm', units === 'aviation' ? 3.280839895 : 1);
}
export function fuel(entity) { return measurement(entity?.fuel?.ratioRaw, entity?.fuel?.status, '%', 100); }
export function playerLabel(entity) {
  const player = entity?.occupancy?.isPlayer ?? entity?.isPlayer;
  return player === true ? '玩家' : player === false ? 'AI' : '身份未知';
}
export function weapons(entity) {
  const block = entity?.armament;
  if (!Array.isArray(block?.items)) return { known: false, quality: block?.status ?? 'unavailable', items: [] };
  return { known: true, quality: block.status, items: block.items.map(item => ({
    key: item.weaponKey, name: item.displayName || item.typeName || '未知武器', category: item.category,
    count: finite(item.count) ? item.count : null,
  })) };
}
export function missileTarget(missile) {
  const current = missile?.targetObservation;
  const previous = missile?.lastKnownTarget;
  if (current?.status === 'object' && current.object) return { label: '当前观察', object: current.object, known: true, stale: false };
  if (current?.status === 'none_reported') return { label: '未报告目标', object: null, known: false, stale: false,
    previous: previous?.object ?? null };
  const object = current?.object ?? previous?.object ?? null;
  return { label: object ? '最后观察' : '目标未知', object, known: false, stale: Boolean(object) };
}
export function launcher(missile) {
  const observed = missile?.launch?.launcher;
  return { label: observed?.status === 'conflict' ? '来源冲突' : observed?.status === 'known' ? '发射者' : '发射者未知',
    object: observed?.object ?? null, alternate: observed?.alternateObject ?? null, status: observed?.status ?? 'unknown' };
}
export function missileLabels(missile) {
  const from=launcher(missile);
  return {name:missile.identity?.typeName||missile.typeName||'未知导弹',
    launcher:from.status==='known'&&from.object?entityName(from.object):from.status==='conflict'?'发射来源冲突':'未知发射人'};
}
export function telemetryFresh(latest,localStatus='connected',now=Date.now(),snapshot=true) {
  const s=latest?.source,elapsed=Math.max(0,(now-(latest?.sourcesReceivedAt??0))/1000);
  return localStatus==='connected'&&latest?.connection==='connected'&&s?.online===true&&s.statusFresh===true&&
    ['running','paused'].includes(s.lifecycle)&&finite(s.statusAgeSec)&&s.statusAgeSec+elapsed<3&&
    (!snapshot||(s.snapshotFresh===true&&finite(s.snapshotAgeSec)&&s.snapshotAgeSec+elapsed<3));
}
// Only current targets count. Historical targets and display filters never participate.
export function incomingMissiles(latest,localStatus='connected',now=Date.now()) {
  const result=new Map();if(!telemetryFresh(latest,localStatus,now))return result;
  const seen=new Set();
  for(const m of latest.snapshot?.entities??[]) {
    if(m.kind!=='missile'||!m.entityId||seen.has(m.entityId))continue;seen.add(m.entityId);
    const target=missileTarget(m);if(!target.known||!target.object?.entityId)continue;
    const id=target.object.entityId;if(!result.has(id))result.set(id,[]);result.get(id).push(m);
  }
  return result;
}
export function aircraftForOutput(state, config) {
  const search = (config.filters.search ?? '').trim().toLocaleLowerCase();
  const result = (state?.entities ?? []).filter(entity => entity.kind === 'aircraft' &&
    (config.filters.coalition === 'all' || coalition(entity) === config.filters.coalition) &&
    (!config.filters.playersOnly || entity.occupancy?.isPlayer === true) &&
    (!search || [entityName(entity), entity.identity?.typeName, entity.identity?.unitName].some(value => value?.toLocaleLowerCase().includes(search))));
  const value = entity => ({speed:entity.motion?.speedMps, fuel:entity.fuel?.ratioRaw, altitude:entity.motion?.position?.y})[config.filters.sortBy];
  return result.sort((a,b) => config.filters.sortBy && config.filters.sortBy !== 'name' ?
    (finite(value(b)) ? value(b) : -Infinity) - (finite(value(a)) ? value(a) : -Infinity) || entityName(a).localeCompare(entityName(b),'zh-CN') :
    entityName(a).localeCompare(entityName(b),'zh-CN'));
}
export function selectedAircraft(latest,config){
  return (latest?.snapshot?.entities??[]).find(e=>e.kind==='aircraft'&&e.entityId===config.aircraftId)??null;
}
export function missilesForOutput(state, config) {
  return (state?.entities ?? []).filter(entity => entity.kind === 'missile' &&
    (config.filters.coalition === 'all' || coalition(entity) === config.filters.coalition) &&
    (!config.filters.missileFocusOnly || (config.aircraftId !== null && entity.launch?.launcher?.object?.entityId === config.aircraftId)));
}
export function eventText(event) {
  const label = EVENT_LABELS[event.type] ?? event.type ?? '事件';
  const actor = event.actor ? entityName(event.actor) : '';
  const target = event.target ? entityName(event.target) : '';
  if (event.type === 'capture_record_rejected') return `${label} · ${event.details?.originalType ?? '未知类型'}`;
  return [actor, label, target].filter(Boolean).join(' · ');
}
export function missionTime(seconds) {
  if (!finite(seconds) || seconds < 0) return '—';
  const n = Math.floor(seconds);return `${String(Math.floor(n / 3600)).padStart(2, '0')}:${String(Math.floor(n / 60) % 60).padStart(2, '0')}:${String(n % 60).padStart(2, '0')}`;
}
