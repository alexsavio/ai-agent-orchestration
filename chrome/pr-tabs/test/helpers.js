import { readFileSync } from "node:fs";
import { compileRules } from "../extension/core.js";

export const rules = compileRules({
  ...JSON.parse(readFileSync(new URL("../extension/rules.json", import.meta.url))),
  topics: JSON.parse(
    readFileSync(new URL("./fixtures/topics.json", import.meta.url)),
  ),
  org: "acme",
  defaultRepo: "webapp",
});
