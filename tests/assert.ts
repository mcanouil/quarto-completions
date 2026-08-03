/**
 * Minimal assertions, so the test suite imports nothing from the network and
 * runs under whatever runtime `quarto run` provides.
 */

export class AssertionError extends Error {}

export function assert(condition: boolean, message: string): void {
  if (!condition) {
    throw new AssertionError(message);
  }
}

export function assertEquals<T>(actual: T, expected: T, message?: string): void {
  const left = JSON.stringify(actual);
  const right = JSON.stringify(expected);
  if (left !== right) {
    throw new AssertionError(
      `${message ?? "values differ"}\n  actual:   ${left}\n  expected: ${right}`,
    );
  }
}

export function assertIncludes(haystack: string, needle: string, message?: string): void {
  if (!haystack.includes(needle)) {
    throw new AssertionError(
      `${message ?? "missing substring"}\n  expected to find: ${needle}`,
    );
  }
}

export function assertExcludes(haystack: string, needle: string, message?: string): void {
  if (haystack.includes(needle)) {
    throw new AssertionError(
      `${message ?? "unexpected substring"}\n  expected not to find: ${needle}`,
    );
  }
}
