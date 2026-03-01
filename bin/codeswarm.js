#!/usr/bin/env node
const { execFileSync } = require('child_process');
const path = require('path');

const args = process.argv.slice(2);
const root = path.join(__dirname, '..');

// Route: "codeswarm gsd ..." → gsd.sh, otherwise → coordinator.sh
let script;
let scriptArgs;

if (args[0] === 'gsd') {
    script = path.join(root, 'gsd.sh');
    scriptArgs = args.slice(1);
} else {
    script = path.join(root, 'coordinator.sh');
    scriptArgs = args;
}

try {
    execFileSync('bash', [script, ...scriptArgs], {
        stdio: 'inherit',
        env: { ...process.env, CODESWARM_ROOT: root }
    });
} catch (e) {
    process.exit(e.status || 1);
}
