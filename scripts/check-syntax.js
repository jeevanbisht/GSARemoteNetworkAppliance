const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const root = process.cwd();
const skipDirs = new Set(["node_modules", ".git", "infra", "docs", "operations"]);
const files = [];

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) {
      continue;
    }
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!skipDirs.has(entry.name)) {
        walk(fullPath);
      }
      continue;
    }
    if (entry.isFile() && fullPath.endsWith(".js")) {
      files.push(fullPath);
    }
  }
}

walk(path.join(root, "apps"));
walk(path.join(root, "packages"));
walk(path.join(root, "scripts"));

let failed = false;
for (const file of files) {
  const result = spawnSync(process.execPath, ["--check", file], { stdio: "pipe" });
  if (result.status !== 0) {
    failed = true;
    process.stderr.write(result.stderr.toString());
  }
}

if (failed) {
  process.exit(1);
}

console.log(`Syntax check passed for ${files.length} file(s).`);
