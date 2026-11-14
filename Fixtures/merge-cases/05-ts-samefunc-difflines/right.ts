export function process(items: number[]): number {
  let sum = 0;
  const offset = 1;
  for (const i of items) {
    sum += i;
  }
  const tax = 2;
  sum += tax;
  const bonus = 30;
  sum += bonus;
  return sum + offset;
}

export function other(): number {
  return 7;
}
