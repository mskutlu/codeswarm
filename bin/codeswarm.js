#!/usr/bin/env node
const { execFileSync } = require('child_process');
const path = require('path');

const coordinator = path.join(__dirname, '..', 'coordinator.sh');
const args = process.argv.slice(2);

try {
    execFileSync('bash', [coordinator, ...args], {
        stdio: 'inherit',
        env: { ...process.env, CODESWARM_ROOT: path.join(__dirname, '..') }
    });
} catch (e) {
    process.exit(e.status || 1);
}
