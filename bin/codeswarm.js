#!/usr/bin/env node
const { execFileSync } = require('child_process');
const path = require('path');

const args = process.argv.slice(2);
const root = path.join(__dirname, '..');
const gsdRoot = path.join(root, 'gsd');

// Route:
//   codeswarm gsd install [flags] → GSD's real install.js
//   codeswarm gsd [run] [flags]   → multi-agent orchestrator (gsd.sh)
//   codeswarm [flags]              → coordinator.sh
if (args[0] === 'gsd') {
    const subcommand = args[1];

    if (subcommand === 'install') {
        // Run GSD's real installer from our bundled copy
        const installer = path.join(gsdRoot, 'bin', 'install.js');
        const installArgs = args.slice(2);
        try {
            execFileSync('node', [installer, ...installArgs], {
                stdio: 'inherit',
                env: { ...process.env, CODESWARM_ROOT: root, GSD_ROOT: gsdRoot }
            });
        } catch (e) {
            process.exit(e.status || 1);
        }
    } else {
        // 'codeswarm gsd run ...' or 'codeswarm gsd --project ...'
        const script = path.join(root, 'gsd.sh');
        const scriptArgs = subcommand === 'run' ? args.slice(2) : args.slice(1);
        try {
            execFileSync('bash', [script, ...scriptArgs], {
                stdio: 'inherit',
                env: { ...process.env, CODESWARM_ROOT: root, GSD_ROOT: gsdRoot }
            });
        } catch (e) {
            process.exit(e.status || 1);
        }
    }
} else {
    const script = path.join(root, 'coordinator.sh');
    try {
        execFileSync('bash', [script, ...args], {
            stdio: 'inherit',
            env: { ...process.env, CODESWARM_ROOT: root }
        });
    } catch (e) {
        process.exit(e.status || 1);
    }
}
