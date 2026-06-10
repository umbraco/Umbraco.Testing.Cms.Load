export interface Summary {
  count: number;
  median: number;
  p75: number;
  p95: number;
  min: number;
  max: number;
  stddev: number;
}

// Nearest-rank percentile on a sorted copy. p(50) returns the mean of the two
// middle values for even-length input (classic median), higher percentiles use
// nearest-rank for stability on small N.
function percentile(sorted: number[], p: number): number {
  if (sorted.length === 1) return sorted[0];
  if (p === 50) {
    const mid = sorted.length / 2;
    return Number.isInteger(mid)
      ? (sorted[mid - 1] + sorted[mid]) / 2
      : sorted[Math.floor(mid)];
  }
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(rank, sorted.length) - 1];
}

export function summarize(values: number[]): Summary {
  if (values.length === 0) {
    return { count: 0, median: 0, p75: 0, p95: 0, min: 0, max: 0, stddev: 0 };
  }
  const sorted = [...values].sort((a, b) => a - b);
  const mean = sorted.reduce((acc, v) => acc + v, 0) / sorted.length;
  const variance = sorted.reduce((acc, v) => acc + (v - mean) ** 2, 0) / sorted.length;
  return {
    count: sorted.length,
    median: percentile(sorted, 50),
    p75: percentile(sorted, 75),
    p95: percentile(sorted, 95),
    min: sorted[0],
    max: sorted[sorted.length - 1],
    stddev: Math.sqrt(variance),
  };
}
