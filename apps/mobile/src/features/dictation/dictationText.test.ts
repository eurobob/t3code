import { describe, expect, it } from "@effect/vitest";

import { appendDictatedText, rollbackDictatedText } from "./dictationText";

describe("appendDictatedText", () => {
  it("uses the phrase alone when the draft is empty", () => {
    expect(appendDictatedText("", "add a test")).toEqual({
      next: "add a test",
      appended: "add a test",
    });
  });

  it("separates from existing text with a single space", () => {
    expect(appendDictatedText("first phrase", "second phrase")).toEqual({
      next: "first phrase second phrase",
      appended: " second phrase",
    });
  });

  it("does not add a separator when the draft already ends in whitespace", () => {
    expect(appendDictatedText("first phrase\n", "second")).toEqual({
      next: "first phrase\nsecond",
      appended: "second",
    });
  });

  it("ignores a phrase that is only whitespace", () => {
    expect(appendDictatedText("unchanged", "   ")).toEqual({
      next: "unchanged",
      appended: "",
    });
  });
});

describe("rollbackDictatedText", () => {
  it("removes the appended text along with its separator", () => {
    const { next, appended } = appendDictatedText("typed by hand", "dictated");
    expect(rollbackDictatedText(next, appended)).toBe("typed by hand");
  });

  it("restores an empty draft exactly", () => {
    const { next, appended } = appendDictatedText("", "dictated");
    expect(rollbackDictatedText(next, appended)).toBe("");
  });

  // The important case: cancelling must never eat text the user typed.
  it("leaves the draft alone when the user edited after dictating", () => {
    const { next, appended } = appendDictatedText("start", "dictated");
    const edited = `${next} and then typed more`;
    expect(rollbackDictatedText(edited, appended)).toBe(edited);
  });

  it("leaves the draft alone when the transcript was deleted already", () => {
    const { appended } = appendDictatedText("start", "dictated");
    expect(rollbackDictatedText("start", appended)).toBe("start");
  });

  it("is a no-op when nothing was committed", () => {
    expect(rollbackDictatedText("untouched", "")).toBe("untouched");
  });
});
