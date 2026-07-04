#!/usr/bin/env node
// Compiles every corpus project with the oracle compiler, runs the JS
// under Node, and diffs the lines sent through `port emit` against
// the project's expected.txt.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const corpusDir = __dirname;
const oracle =
  process.env.ELM_ORACLE || path.join(corpusDir, "..", "bin", "elm");

// Cmds from init are dispatched on the next tick; 50ms is generous for the
// current corpus projects. Override via ELM_CORPUS_SETTLE_MS if needed.
const SETTLE_MS = Number(process.env.ELM_CORPUS_SETTLE_MS) || 50;

function runProject(name) {
  const dir = path.join(corpusDir, name);
  const out = path.join(dir, "elm-stuff", "corpus-out.js");
  execFileSync(oracle, ["make", "src/Main.elm", "--output=" + out], {
    cwd: dir,
    stdio: ["ignore", "ignore", "inherit"],
  });
  const { Elm } = require(out);
  const lines = [];
  const app = Elm.Main.init({});
  app.ports.emit.subscribe((line) => lines.push(line));
  return new Promise((resolve) => {
    setTimeout(() => {
      // A throw here would escape main()'s try (async); report it instead.
      try {
        const got = lines.join("\n") + "\n";
        const expected = fs.readFileSync(
          path.join(dir, "expected.txt"),
          "utf8"
        );
        resolve(got === expected ? null : { got, expected });
      } catch (error) {
        resolve({ error });
      }
    }, SETTLE_MS);
  });
}

async function main() {
  const projects = fs
    .readdirSync(corpusDir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  let failures = 0;
  for (const name of projects) {
    try {
      const diff = await runProject(name);
      if (diff === null) {
        console.log(`${name}: OK`);
      } else if (diff.error) {
        failures++;
        console.error(`${name}: ERROR ${diff.error.message}`);
      } else {
        failures++;
        console.error(`${name}: FAIL\n--- expected\n${diff.expected}--- got\n${diff.got}`);
      }
    } catch (err) {
      failures++;
      console.error(`${name}: ERROR ${err.message}`);
    }
  }
  process.exit(failures === 0 ? 0 : 1);
}

main();
