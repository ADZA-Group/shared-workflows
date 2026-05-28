import { describe, it, expect } from "vitest";
import { add } from "./add";

describe("add", () => {
  it("sums", () => {
    expect(add(2, 3)).toBe(5);
  });
});
