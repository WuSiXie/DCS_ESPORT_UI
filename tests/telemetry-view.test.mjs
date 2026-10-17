import { test } from 'node:test';
import assert from 'node:assert/strict';
import { defaultConfig, EVENT_TYPES } from '../src/director/output-model.mjs';
import { EVENT_LABELS, speed, altitude, fuel, weapons, playerLabel, missileTarget, launcher,
  aircraftForOutput, missilesForOutput, missionTime } from '../src/web/telemetry.mjs';

test('unknown telemetry never masquerades as zero or an empty loadout', () => {
  assert.equal(speed({}).value, null);assert.equal(fuel({}).text, '—');
  assert.equal(weapons({}).known, false);assert.equal(playerLabel({}), '身份未知');
  assert.equal(speed({ motion: { speedMps: 0, status: 'ok' } }).text, '0');
  assert.equal(fuel({ fuel: { ratioRaw: 1.2, status: 'ok' } }).text, '120');
  assert.equal(altitude({ motion: { position: { y: 1000 }, status: 'stale' } }, 'metric').stale, true);
  assert.equal(weapons({ armament: { items: [], status: 'ok' } }).known, true);
  assert.equal(playerLabel({ occupancy: { isPlayer: false } }), 'AI');
});
test('current, absent and stale missile targets remain distinct', () => {
  const target = { entityId: 'aircraft-1', name: '目标' };
  const m = { targetObservation: { status: 'none_reported' }, lastKnownTarget: { object: target } };
  assert.equal(missileTarget(m).object, null);assert.equal(missileTarget(m).previous.entityId, 'aircraft-1');
  m.targetObservation = { status: 'unavailable' };
  assert.equal(missileTarget(m).stale, true);assert.equal(missileTarget(m).known, false);
  m.targetObservation = { status: 'object', object: target };
  assert.equal(missileTarget(m).known, true);
  assert.equal(launcher({ launch: { launcher: { status: 'conflict', object: target } } }).label, '来源冲突');
});
test('output filters do not mutate shared telemetry and all supported events have labels', () => {
  const config = defaultConfig();config.filters.playersOnly = true;
  const state = { entities: [{ kind: 'aircraft', entityId: 'a', occupancy: { isPlayer: true } },
    { kind: 'aircraft', entityId: 'b', occupancy: { isPlayer: false } },
    { kind: 'missile', entityId: 'm', launch: { launcher: { object: { entityId: 'a' } } } }] };
  assert.equal(aircraftForOutput(state, config).length, 1);assert.equal(state.entities.length, 3);
  config.filters.missileFocusOnly = true;config.aircraftId = 'a';
  assert.equal(missilesForOutput(state, config).length, 1);config.aircraftId = null;
  assert.equal(missilesForOutput(state, config).length, 0);
  for (const type of EVENT_TYPES) assert.ok(EVENT_LABELS[type]);
  assert.equal(missionTime(3661.7), '01:01:01');assert.equal(missionTime(null), '—');
});
