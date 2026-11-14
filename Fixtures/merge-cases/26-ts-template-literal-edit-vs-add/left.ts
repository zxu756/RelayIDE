interface User {
  name: string;
  age: number;
}

export function render(u: User): string {
  return `
Name: ${u.name}

Age: ${u.age} years
`;
}

export function isAdult(u: User): boolean {
  return u.age >= 18;
}
