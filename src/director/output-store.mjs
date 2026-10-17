import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { LAYOUTS, newOutput, migrateRetiredFeatures, validateConfig, publicOutput, ValidationError } from './output-model.mjs';

export class OutputStore {
  constructor(directory) { this.directory = directory; this.outputs = []; this.queue = Promise.resolve(); }
  async load() {
    await mkdir(this.directory, { recursive: true });
    try {
      const saved = JSON.parse(await readFile(join(this.directory, 'outputs.json'), 'utf8'));
      if (saved.version !== 1 || !Array.isArray(saved.outputs) || saved.outputs.length > 12) throw new Error('无效的画面配置文件');
      const ids = new Set();
      this.outputs = saved.outputs.map(output => {
        if (typeof output.id !== 'string' || !/^[a-f0-9-]{36}$/u.test(output.id) || ids.has(output.id) ||
            !/^[a-f0-9]{64}$/u.test(output.readKey) || !Number.isSafeInteger(output.revision) || output.revision < 1)
          throw new Error('画面身份或版本无效');
        ids.add(output.id);return { ...output, config: validateConfig(migrateRetiredFeatures(output.config)) };
      });
      if(JSON.stringify(saved.outputs)!==JSON.stringify(this.outputs))await this.persist(this.outputs);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error; // Preserve corrupt data instead of replacing it silently.
      this.outputs = LAYOUTS.map(layout => newOutput(layout));await this.persist(this.outputs);
    }
    return this;
  }
  async persist(outputs) {
    const temporary = join(this.directory, `.outputs-${randomUUID()}.tmp`);
    await writeFile(temporary, JSON.stringify({ version: 1, outputs }, null, 2), { mode: 0o600 });
    await rename(temporary, join(this.directory, 'outputs.json'));
  }
  list() { return this.outputs.map(publicOutput); }
  get(id) { return this.outputs.find(output => output.id === id); }
  transact(operation) {
    const pending = this.queue.then(async () => {
      const next = structuredClone(this.outputs);const result = operation(next);
      await this.persist(next);this.outputs = next;return result;
    });
    this.queue = pending.catch(() => {});return pending;
  }
  create(config) {
    return this.transact(outputs => {
      if (outputs.length >= 12) throw new ValidationError('每个导播服务最多管理 12 个输出', 409);
      const output = newOutput('overview', config);outputs.push(output);return publicOutput(output);
    });
  }
  update(id, revision, config) {
    const checked = validateConfig(config);
    return this.transact(outputs => {
      const output = outputs.find(item => item.id === id);
      if (!output) throw new ValidationError('画面不存在', 404);
      if (output.revision !== revision) throw new ValidationError('画面已被其他控制页修改，请刷新后重试', 409);
      output.config = checked;output.revision++;return publicOutput(output);
    });
  }
  remove(id, revision) {
    return this.transact(outputs => {
      const index = outputs.findIndex(item => item.id === id);
      if (index < 0) throw new ValidationError('画面不存在', 404);
      if (outputs[index].revision !== revision) throw new ValidationError('画面已更改，请刷新后重试', 409);
      outputs.splice(index, 1);return { removed: id };
    });
  }
}
