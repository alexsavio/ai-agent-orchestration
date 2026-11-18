const test = require("node:test");
const assert = require("node:assert/strict");
const logic = require("../coordinator/todo-panel.js");

const items = [{ key: "k1" }, { key: "k2" }, { key: "k3" }];
let counter = 0;
const makeId = () => "id" + ++counter;

test("visibleItems hides the items already sent", () => {
  const shown = logic.visibleItems(items, [{ id: "a", key: "k2", answer: "x" }]);
  assert.deepEqual(shown.map((item) => item.key), ["k1", "k3"]);
});

test("collectAnswers takes only the items that have an answer", () => {
  const entries = logic.collectAnswers(items, { k1: "now", k2: "   ", k3: " later " }, makeId);
  assert.deepEqual(entries.map(({ key, answer }) => [key, answer]), [["k1", "now"], ["k3", "later"]]);
});

test("collectAnswers cuts an answer at the limit", () => {
  const [entry] = logic.collectAnswers(items, { k1: "x".repeat(600) }, makeId);
  assert.equal(entry.answer.length, logic.ANSWER_MAX);
});

test("mergePending keeps earlier entries and replaces one with the same id", () => {
  const merged = logic.mergePending(
    [{ id: "a", key: "k1", answer: "old" }, { id: "b", key: "k2", answer: "keep" }],
    [{ id: "a", key: "k1", answer: "new" }, { id: "c", key: "k3", answer: "add" }],
  );
  assert.deepEqual(merged.map((entry) => [entry.id, entry.answer]), [["a", "new"], ["b", "keep"], ["c", "add"]]);
});

test("parseAnswers survives a missing or broken file", () => {
  assert.deepEqual(logic.parseAnswers("not json"), []);
  assert.deepEqual(logic.parseAnswers("{}"), []);
  assert.deepEqual(logic.parseAnswers('{"answers":[{"id":"a","key":"k"},{"id":1}]}'), [{ id: "a", key: "k" }]);
});

test("classifyError maps each code to one handling", () => {
  assert.equal(logic.classifyError("conflict"), "reload");
  for (const code of ["not_writer", "not_granted", "capability_disabled"]) {
    assert.equal(logic.classifyError(code), "read-only");
  }
  for (const code of ["rate_limited", "too_large", "upstream_error", undefined]) {
    assert.equal(logic.classifyError(code), "failed");
  }
});
