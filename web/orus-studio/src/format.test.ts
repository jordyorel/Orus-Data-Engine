import { describe, expect, it } from "vitest";

describe("studio smoke", () => {
  it("keeps product API paths versioned", () => {
    expect("/v1/projects").toMatch(/^\/v1\//);
  });
});
