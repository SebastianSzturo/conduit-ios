#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const sourceUrl = process.env.OPENAPI_SOURCE_URL || "https://api.conductor.build/v0/openapi.json";
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const checkedIn = JSON.parse(await readFile(path.join(scriptDir, "openapi.json"), "utf8"));
const response = await fetch(sourceUrl, {
  headers: { accept: "application/json", "user-agent": "conduit-api-drift-check/1.0" },
});

if (!response.ok) {
  throw new Error(`Failed to fetch ${sourceUrl}: ${response.status} ${response.statusText}`);
}

const live = await response.json();
const normalize = (value) => JSON.stringify(value);

if (normalize(checkedIn) !== normalize(live)) {
  console.error("api/openapi.json differs from the live Conductor API schema.");
  console.error("Run ./api/update-api-docs.mjs and commit the regenerated files.");
  process.exit(1);
}

console.log("api/openapi.json matches the live Conductor API schema.");
