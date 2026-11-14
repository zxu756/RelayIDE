export function calculate(x: number): number {
  const y = x * 2;
  return y + 1;
}

export function use(): number {
  return calculate(3);
}
