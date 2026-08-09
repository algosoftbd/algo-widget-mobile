const { execSync } = require("node:child_process");

// The changelog action bumps package.json and nothing else, so package-lock.json
// keeps the OLD version in its two version fields. `npm ci` tolerates that (the
// root package is not one of its own dependencies), which is exactly why it is
// worth fixing here rather than waiting for a build to complain: nothing breaks,
// the two files simply disagree, and the next `npm install` anybody runs commits
// a spurious version diff on top of unrelated work.
//
// Mirrors scripts/release-pre-commit.cjs in the AlgoSoft OS repo. Attached only
// to the React Native step — the Flutter package has no lockfile to sync.
exports.preCommit = () => {
  execSync("npm install --package-lock-only --ignore-scripts --no-audit --no-fund", {
    cwd: "packages/react-native",
    stdio: "inherit",
  });
};
