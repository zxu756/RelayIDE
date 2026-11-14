interface User {
  name: string;
  age: number;
}

export function render(u: User): string {
  return `
Name: ${u.name}

Age: ${u.age}
`;
}

export function isAdult(u: User): boolean {
  return u.age >= 18;
}

export function initials(u: User): string {
  return u.name.slice(0, 1);
}
