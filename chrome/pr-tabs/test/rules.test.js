import assert from "node:assert/strict";
import { test } from "node:test";
import { compileRules, topicFor } from "../extension/core.js";
import { rules } from "./helpers.js";

const cases = [
  ["Search", { repo: "webapp", title: "feat(ui-search): keyboard support" }],
  ["Search", { repo: "webapp", title: "Search results paging" }],
  ["ui-select", { repo: "webapp", title: "feat: ui-select chips" }],
  ["ui-select", { repo: "webapp", title: "Replace legacy-select" }],
  ["ui-select", { repo: "webapp", title: "Arrow keys", branch: "2644-select-keyboard" }],
  ["ui-menu", { repo: "webapp", title: "fix(ui-menu): focus trap" }],
  ["Rating", { repo: "webapp", title: "feat(ui-rating): half stars" }],
  ["Rating", { repo: "webapp", title: "Stars", branch: "1086-stars" }],
  ["Filters", { repo: "webapp", title: "Filters", branch: "2972-filters-dialog" }],
  ["Filters", { repo: "webapp", title: "Menus and tooltips refresh" }],
  ["Filters", { repo: "webapp", title: "feat(ui-dialog): ignore-outside-click" }],
  ["Filters", { repo: "webapp", title: "feat: ui-tab-group" }],
  ["Tokens", { repo: "webapp", title: "Use custom properties for spacing" }],
  ["Tokens", { repo: "webapp", title: "Colour tokens for dark mode" }],
  ["AI skills", { repo: "claude-skills", title: "Add review skill" }],
  ["AI skills", { repo: "webapp", title: "chore(ai): update agent rules" }],
  ["AI skills", { repo: "webapp", title: "fix(skills): broken link" }],
  ["Infra", { repo: "webapp", title: "Deploy previews on push" }],
  ["Infra", { repo: "webapp", title: "Upgrade vite to 7" }],
  ["Infra", { repo: "webapp", title: "Example-sso callback" }],
  ["Infra", { repo: "webapp", title: "Example-launch" }],
  ["Infra", { repo: "service-app", title: "Tune scoring" }],
  ["Orchestration", { repo: "orchestration-tool", title: "feat: chrome PR tabs" }],
  ["Other", { repo: "webapp", title: "Fix typo in README" }],
];

for (const [topic, pr] of cases) {
  test(`${JSON.stringify(pr)} groups under ${topic}`, () => {
    assert.equal(topicFor(rules, pr).name, topic);
  });
}

test("the first matching topic wins", () => {
  assert.equal(topicFor(rules, { repo: "webapp", title: "ui-search colour tokens" }).name, "Search");
  assert.equal(topicFor(rules, { repo: "orchestration-tool", title: "Deploy watcher" }).name, "Infra");
});

test("a word inside another word does not match", () => {
  assert.equal(topicFor(rules, { repo: "webapp", title: "Research spike" }).name, "Other");
});

test("repo patterns only test the repo, title patterns only the title", () => {
  const custom = compileRules({
    fallback: { name: "Other", color: "grey" },
    topics: [
      { name: "ByRepo", color: "blue", repo: ["^docs$"] },
      { name: "ByTitle", color: "red", title: ["^docs:"] },
    ],
  });
  assert.equal(topicFor(custom, { repo: "webapp", title: "docs" }).name, "Other");
  assert.equal(topicFor(custom, { repo: "docs", title: "x" }).name, "ByRepo");
  assert.equal(topicFor(custom, { repo: "webapp", title: "docs: x" }).name, "ByTitle");
});

test("every topic carries a Chrome tab group colour", () => {
  for (const field of ["repo", "branch", "title", "any"]) {
    assert.throws(() => compileRules({ topics: [{ name: "Bad", color: "blue", [field]: ["("] }] }), /ORCH_PR_TABS_TOPICS/);
  }
  const colours = new Set(["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]);
  for (const topic of [...rules.topics, rules.fallback]) assert.ok(colours.has(topic.color), topic.name);
});
