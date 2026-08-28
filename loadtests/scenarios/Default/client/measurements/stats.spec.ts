import { test, expect } from '@playwright/test';
import { summarize } from '../lib/stats';

test('summarize computes median, p75, p95, stddev', () => {
  const s = summarize([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]);
  expect(s.count).toBe(10);
  expect(s.median).toBe(55);          // mean of 50 and 60
  expect(s.p75).toBe(80);             // nearest-rank p75
  expect(s.p95).toBe(100);            // nearest-rank p95
  expect(s.min).toBe(10);
  expect(s.max).toBe(100);
  expect(Math.round(s.stddev)).toBe(29);
});

test('summarize handles a single value', () => {
  const s = summarize([42]);
  expect(s.median).toBe(42);
  expect(s.p95).toBe(42);
  expect(s.stddev).toBe(0);
});
