import { test, expect } from '@playwright/test';
import { mkdtempSync, readFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { emitMetric } from '../lib/measure';

test('emitMetric appends one NDJSON row with stats + metadata', () => {
  const dir = mkdtempSync(join(tmpdir(), 'cm-'));
  emitMetric('cold_homepage_load', [120, 130, 140], { extra: 'x' }, dir);
  const file = join(dir, 'cold_homepage_load.ndjson');
  const row = JSON.parse(readFileSync(file, 'utf8').trim());
  expect(row.metric).toBe('cold_homepage_load');
  expect(row.median).toBe(130);
  expect(row.count).toBe(3);
  expect(row.extra).toBe('x');
  expect(row.run_id).toBeTruthy();
});
