class Counter {
  constructor() {
    this.value = 0;
  }

  increment() {
    this.value += 1;
  }

  /** Reset to zero. */
  reset() {
    this.value = 0;
  }

  /** Subtract one. */
  decrement() {
    this.value -= 1;
  }
}

module.exports = { Counter };
