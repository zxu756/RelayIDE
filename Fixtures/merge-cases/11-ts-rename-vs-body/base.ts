export function compute(x: number): number {
  const y = x * 2;
  return y + 1;
}

export function use(): number {
  return compute(3);
}
