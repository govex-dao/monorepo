import { describe, it, expect } from "vitest";

describe("Hello World Test", () => {
  it("confirms that true is true", () => {
    expect(true).toBe(true);
  });

  it("confirms basic math works", () => {
    expect(1 + 1).toBe(2);
  });
});
