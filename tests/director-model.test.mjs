import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { FEATURES, defaultConfig, validateConfig, publicOutput } from '../src/director/output-model.mjs';
import { OutputStore } from '../src/director/output-store.mjs';

test('every UI feature can be disabled independently and unknown settings are rejected', () => {
  for (const feature of Object.keys(FEATURES)) {
    const config = defaultConfig();config.features[feature] = false;
    assert.equal(validateConfig(config).features[feature], false);
    assert.equal(Object.values(config.features).filter(Boolean).length, Object.keys(FEATURES).length - 1);
  }
  assert.throws(() => validateConfig({ ...defaultConfig(), html: '<script>' }));
  assert.throws(() => validateConfig({ ...defaultConfig(), eventCount: 1000 }));
  assert.throws(() => validateConfig({ ...defaultConfig(), features: {} }));
});

test('legacy HUD profiles preserve old switches and default only the new data switches', () => {
  const legacy=defaultConfig();legacy.features.map=false;legacy.features.roster=false;
  for(const key of ['fuel','speed','altitude','loadout'])delete legacy.features[key];
  const migrated=validateConfig(legacy);
  assert.equal(migrated.features.map,false);assert.equal(migrated.features.roster,false);
  for(const key of ['fuel','speed','altitude','loadout'])assert.equal(migrated.features[key],true);
  legacy.features.fuel=null;assert.throws(()=>validateConfig(legacy));
  assert.equal(defaultConfig().appearance.transparent,true);
});
test('independent outputs survive restart and concurrent writes detect revision conflicts', async () => {
  const root = resolve('runtime/director-tests');await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, 'outputs-'));
  try {
    const store = await new OutputStore(dir).load();const [a, b] = store.list();
    const config = structuredClone(a.config);config.features.map = false;config.match.blueName = '测试队';
    const writes = await Promise.allSettled([store.update(a.id, 1, config), store.update(a.id, 1, config)]);
    assert.equal(writes.filter(result => result.status === 'fulfilled').length, 1);
    assert.equal(writes.find(result => result.status === 'rejected').reason.status, 409);
    assert.equal(store.get(b.id).config.features.map, true);
    const reloaded = await new OutputStore(dir).load();
    assert.equal(reloaded.get(a.id).config.features.map, false);
    assert.equal(reloaded.get(a.id).config.match.blueName, '测试队');
    assert.equal(reloaded.get(a.id).revision, 2);
    assert.equal(reloaded.get(a.id).readKey, store.get(a.id).readKey);
    assert.equal('readKey' in publicOutput(reloaded.get(a.id)), false);
    const copy = await reloaded.create(reloaded.get(a.id).config);
    assert.notEqual(reloaded.get(copy.id).readKey, reloaded.get(a.id).readKey);
    await reloaded.remove(a.id, 2);assert.equal(reloaded.get(a.id), undefined);
  } finally {
    assert.ok(resolve(dir).startsWith(root + sep));
    await rm(dir, { recursive: true, force: true });
  }
});
