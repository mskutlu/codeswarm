#!/usr/bin/env node
const express = require('express');
const http = require('http');
const { WebSocketServer } = require('ws');
const chokidar = require('chokidar');
const fs = require('fs');
const path = require('path');

// ─── Parse args ───────────────────────────────────────
const args = process.argv.slice(2);
let projectDir = '';
let sessionId = '';
let port = 3777;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--project' || args[i] === '-p') projectDir = args[++i];
  else if (args[i] === '--session' || args[i] === '-s') sessionId = args[++i];
  else if (args[i] === '--port') port = parseInt(args[++i], 10);
  else if (args[i] === '--help' || args[i] === '-h') {
    console.log(`
Agentic Dashboard — Real-time monitoring for multi-agent coordinator

Usage:
  node server.js --project <path> [--session <id>] [--port 3777]

Options:
  --project, -p   Path to project with .agentic/ directory (required)
  --session, -s   Specific session ID (default: latest)
  --port          Server port (default: 3777)
`);
    process.exit(0);
  }
}

if (!projectDir) {
  console.error('ERROR: --project <path> is required');
  process.exit(1);
}

projectDir = path.resolve(projectDir);
const agenticDir = path.join(projectDir, '.agentic');
const sessionsDir = path.join(agenticDir, 'sessions');

if (!fs.existsSync(agenticDir)) {
  console.error(`ERROR: ${agenticDir} does not exist`);
  process.exit(1);
}

// ─── Find session ─────────────────────────────────────
function findLatestSession() {
  if (!fs.existsSync(sessionsDir)) return null;
  const dirs = fs.readdirSync(sessionsDir)
    .filter(d => d.startsWith('session_'))
    .sort()
    .reverse();
  return dirs[0] || null;
}

function getSessionDir() {
  const sid = sessionId || findLatestSession();
  if (!sid) return null;
  return path.join(sessionsDir, sid);
}

// ─── Parse session data ───────────────────────────────
function stripAnsi(str) {
  return str.replace(/\x1b\[[0-9;]*m/g, '');
}

function parseCoordinatorLog(sessionPath) {
  const logFile = path.join(sessionPath, 'coordinator.log');
  if (!fs.existsSync(logFile)) return [];
  const raw = fs.readFileSync(logFile, 'utf-8');
  const lines = raw.split('\n').filter(Boolean);
  return lines.map(line => {
    const clean = stripAnsi(line);
    return { raw: clean, ts: extractTimestamp(clean) };
  });
}

function extractTimestamp(line) {
  const m = line.match(/^\[(\d{2}:\d{2}:\d{2})\]/);
  return m ? m[1] : null;
}

function parseTaskFile(sessionPath) {
  const taskFile = path.join(projectDir, '.agentic', 'task.md');
  if (!fs.existsSync(taskFile)) return { title: '', subtasks: [], isPrd: false };

  const raw = fs.readFileSync(taskFile, 'utf-8');
  const titleMatch = raw.match(/^# Task:\s*(.+)/m);
  const title = titleMatch ? titleMatch[1].trim() : '';

  // Detect if this is a PRD-derived task (has [US-XXX] tags)
  const isPrd = /\[US-\d+\]/.test(raw);

  const subtasks = [];
  const lines = raw.split('\n');
  let currentSubtask = null;
  for (const line of lines) {
    const m = line.match(/^(\d+):?\s*- \[(.)\]\s*(.+)/);
    const m2 = !m ? line.match(/- \[(.)\]\s*(.+)/) : null;
    if (m || m2) {
      const checkbox = m ? m[2] : m2[1];
      const text = m ? m[3].trim() : m2[2].trim();
      const status = checkbox === 'x' ? 'done' : checkbox === '/' ? 'in_progress' : 'pending';

      // Extract [US-XXX] tag if present
      const usMatch = text.match(/^\*?\*?\[?(US-\d+)\]?/);
      const storyId = usMatch ? usMatch[1] : null;

      currentSubtask = { num: subtasks.length + 1, status, title: text, storyId, acceptanceCriteria: [] };
      subtasks.push(currentSubtask);
    } else if (currentSubtask && line.match(/^\s+- Acceptance Criteria:/)) {
      // Mark next lines as AC
    } else if (currentSubtask && line.match(/^\s{4,}- \[(.)\]/)) {
      const acMatch = line.match(/^\s{4,}- \[(.)\]\s*(.+)/);
      if (acMatch) {
        currentSubtask.acceptanceCriteria.push({
          status: acMatch[1] === 'x' ? 'pass' : acMatch[1] === '/' ? 'in_progress' : 'pending',
          text: acMatch[2].trim()
        });
      }
    }
  }
  return { title, subtasks, isPrd };
}

function getAgentFiles(sessionPath) {
  if (!fs.existsSync(sessionPath)) return [];
  const files = fs.readdirSync(sessionPath);
  const agents = {};

  for (const f of files) {
    const logMatch = f.match(/^log_(\d+)_(\w+)\.md$/);
    if (logMatch) {
      const seq = parseInt(logMatch[1], 10);
      const name = logMatch[2];
      if (!agents[name]) agents[name] = { name, logs: [], prompts: [] };
      const filePath = path.join(sessionPath, f);
      const stat = fs.statSync(filePath);
      agents[name].logs.push({
        seq,
        file: f,
        size: stat.size,
        mtime: stat.mtimeMs
      });
    }

    const promptMatch = f.match(/^prompt_(\d+)_(\w+)\.md$/);
    if (promptMatch) {
      const seq = parseInt(promptMatch[1], 10);
      const name = promptMatch[2];
      if (!agents[name]) agents[name] = { name, logs: [], prompts: [] };
      agents[name].prompts.push({ seq, file: f });
    }
  }

  return Object.values(agents).map(a => ({
    ...a,
    logs: a.logs.sort((x, y) => x.seq - y.seq),
    prompts: a.prompts.sort((x, y) => x.seq - y.seq),
    latestLog: a.logs.length > 0 ? a.logs[a.logs.length - 1] : null
  }));
}

function getAgentLogTail(sessionPath, logFile, lines = 50) {
  const filePath = path.join(sessionPath, logFile);
  if (!fs.existsSync(filePath)) return '';
  const raw = fs.readFileSync(filePath, 'utf-8');
  const allLines = raw.split('\n');
  return stripAnsi(allLines.slice(-lines).join('\n'));
}

function parseDirectives(sessionPath) {
  if (!fs.existsSync(sessionPath)) return [];
  const files = fs.readdirSync(sessionPath);
  const directives = files
    .filter(f => f.startsWith('directive_'))
    .sort()
    .map(f => {
      const raw = fs.readFileSync(path.join(sessionPath, f), 'utf-8');
      const clean = stripAnsi(raw);
      const actionMatch = clean.match(/ACTION:\s*(\w+)/i);
      const subtaskMatch = clean.match(/SUBTASK:\s*(\d+)/i);
      const instructMatch = clean.match(/INSTRUCTIONS?:\s*(.+)/i);
      return {
        file: f,
        action: actionMatch ? actionMatch[1] : 'UNKNOWN',
        subtask: subtaskMatch ? parseInt(subtaskMatch[1], 10) : null,
        instructions: instructMatch ? instructMatch[1].trim() : ''
      };
    });
  return directives;
}

function detectAgentRoles(sessionPath) {
  // Primary: read metadata.json written by coordinator
  const metaFile = path.join(sessionPath, 'metadata.json');
  if (fs.existsSync(metaFile)) {
    try {
      const meta = JSON.parse(fs.readFileSync(metaFile, 'utf-8'));
      return {
        planner: meta.planner || null,
        executor: meta.executor || null,
        reviewers: meta.reviewers || [],
        frontendDev: meta.frontendDev || null,
        frontendReviewers: meta.frontendReviewers || []
      };
    } catch (e) { /* fall through to log parsing */ }
  }

  // Fallback: parse coordinator log
  const log = parseCoordinatorLog(sessionPath);
  const roles = { planner: null, executor: null, reviewers: [], frontendDev: null, frontendReviewers: [] };
  for (const entry of log) {
    const line = entry.raw;
    if (line.includes('Planner:')) {
      const m = line.match(/Planner:\s*(\w+)/);
      if (m) roles.planner = m[1];
    }
    if (line.includes('Executor:')) {
      const m = line.match(/Executor:\s*(\w+)/);
      if (m) roles.executor = m[1];
    }
    if (line.includes('Reviewers:') || line.includes('reviewers:')) {
      const m = line.match(/Reviewers?:\s*(.+?)(?:\(|$)/i);
      if (m) roles.reviewers = m[1].trim().split(/[\s,]+/).filter(Boolean);
    }
    if (line.includes('FE Dev:')) {
      const m = line.match(/FE Dev:\s*(\w+)/);
      if (m) roles.frontendDev = m[1];
    }
    if (line.includes('FE Review:')) {
      const m = line.match(/FE Review:\s*(.+?)(?:\(|$)/i);
      if (m) roles.frontendReviewers = m[1].trim().split(/[\s,]+/).filter(Boolean);
    }
  }
  return roles;
}

function getSessionState() {
  const sessionPath = getSessionDir();
  if (!sessionPath || !fs.existsSync(sessionPath)) {
    return { error: 'No session found', sessions: listSessions() };
  }

  const sid = path.basename(sessionPath);
  const coordLog = parseCoordinatorLog(sessionPath);
  const task = parseTaskFile(sessionPath);
  const agents = getAgentFiles(sessionPath);
  const directives = parseDirectives(path.join(sessionPath, 'directives'));
  const roles = detectAgentRoles(sessionPath);

  // Detect current round from coordinator log
  let currentRound = 0;
  for (const entry of coordLog) {
    const m = entry.raw.match(/Round\s+(\d+)/i);
    if (m) currentRound = Math.max(currentRound, parseInt(m[1], 10));
  }

  // Detect running agents (files modified in last 60s)
  const now = Date.now();
  const runningAgents = agents
    .filter(a => a.latestLog && (now - a.latestLog.mtime) < 60000)
    .map(a => a.name);

  return {
    sessionId: sid,
    sessionPath,
    project: projectDir,
    roles,
    currentRound,
    task,
    agents,
    runningAgents,
    directives,
    coordLog: coordLog.slice(-100),
    sessions: listSessions()
  };
}

function listSessions() {
  if (!fs.existsSync(sessionsDir)) return [];
  return fs.readdirSync(sessionsDir)
    .filter(d => d.startsWith('session_'))
    .sort()
    .reverse()
    .slice(0, 20);
}

// ─── Express + WebSocket ──────────────────────────────
const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/state', (req, res) => {
  res.json(getSessionState());
});

app.get('/api/sessions', (req, res) => {
  res.json(listSessions());
});

app.get('/api/session/:sid', (req, res) => {
  sessionId = req.params.sid;
  res.json(getSessionState());
});

app.get('/api/log/:file', (req, res) => {
  const sessionPath = getSessionDir();
  if (!sessionPath) return res.status(404).json({ error: 'No session' });
  const lines = parseInt(req.query.lines) || 200;
  const tail = getAgentLogTail(sessionPath, req.params.file, lines);
  res.json({ content: tail });
});

// Search within a log file
app.get('/api/log-search/:file', (req, res) => {
  const sessionPath = getSessionDir();
  if (!sessionPath) return res.status(404).json({ error: 'No session' });
  const query = (req.query.q || '').toLowerCase();
  if (!query) return res.json({ matches: [], total: 0 });

  const filePath = path.join(sessionPath, req.params.file);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'File not found' });

  const raw = fs.readFileSync(filePath, 'utf-8');
  const allLines = raw.split('\n');
  const matches = [];
  for (let i = 0; i < allLines.length; i++) {
    const clean = stripAnsi(allLines[i]);
    if (clean.toLowerCase().includes(query)) {
      matches.push({ line: i + 1, content: clean });
    }
  }
  res.json({ matches: matches.slice(0, 100), total: matches.length });
});

// Download raw log file
app.get('/api/log-download/:file', (req, res) => {
  const sessionPath = getSessionDir();
  if (!sessionPath) return res.status(404).json({ error: 'No session' });
  const filePath = path.join(sessionPath, req.params.file);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'File not found' });

  // Strip ANSI codes for clean download
  const raw = fs.readFileSync(filePath, 'utf-8');
  const clean = stripAnsi(raw);
  res.setHeader('Content-Disposition', `attachment; filename="${req.params.file}"`);
  res.setHeader('Content-Type', 'text/plain');
  res.send(clean);
});

// Detect agent phase from log content
app.get('/api/log-phases/:file', (req, res) => {
  const sessionPath = getSessionDir();
  if (!sessionPath) return res.status(404).json({ error: 'No session' });
  const filePath = path.join(sessionPath, req.params.file);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'File not found' });

  const raw = fs.readFileSync(filePath, 'utf-8');
  const clean = stripAnsi(raw);
  const phases = detectPhases(clean);
  res.json({ phases, currentPhase: phases.length > 0 ? phases[phases.length - 1].phase : null });
});

function detectPhases(logContent) {
  const phases = [];
  const lines = logContent.split('\n');
  const phasePatterns = [
    { pattern: /reading|read file|view_file|cat |examining|analyzing/i, phase: 'Reading' },
    { pattern: /writing|write_to_file|creating file|edit |modifying|implement/i, phase: 'Implementing' },
    { pattern: /test|jest|mocha|pytest|mvn test|npm test|running tests/i, phase: 'Testing' },
    { pattern: /build|compile|mvn compile|npm run build|tsc/i, phase: 'Building' },
    { pattern: /git commit|git add|committing/i, phase: 'Committing' },
    { pattern: /review|checking|verif|validat/i, phase: 'Reviewing' },
  ];

  for (let i = 0; i < lines.length; i++) {
    for (const { pattern, phase } of phasePatterns) {
      if (pattern.test(lines[i])) {
        if (phases.length === 0 || phases[phases.length - 1].phase !== phase) {
          phases.push({ phase, line: i + 1 });
        }
        break;
      }
    }
  }
  return phases;
}

// WebSocket broadcast
function broadcast(data) {
  const msg = JSON.stringify(data);
  wss.clients.forEach(client => {
    if (client.readyState === 1) client.send(msg);
  });
}

// File watcher
let watcher = null;

function startWatching() {
  const sessionPath = getSessionDir();
  if (!sessionPath) return;

  if (watcher) watcher.close();

  const watchPaths = [sessionPath, path.join(agenticDir, 'task.md')];
  watcher = chokidar.watch(watchPaths, {
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 500, pollInterval: 200 }
  });

  watcher.on('all', (event, filePath) => {
    broadcast({ type: 'update', event, file: path.basename(filePath), state: getSessionState() });
  });

  // Also watch for new sessions
  chokidar.watch(sessionsDir, { depth: 0, ignoreInitial: true }).on('addDir', () => {
    const latest = findLatestSession();
    if (latest && latest !== sessionId) {
      sessionId = latest;
      startWatching();
      broadcast({ type: 'new_session', sessionId: latest, state: getSessionState() });
    }
  });
}

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({ type: 'init', state: getSessionState() }));
});

// ─── Start ────────────────────────────────────────────
server.listen(port, () => {
  console.log(`\n🎯 Agentic Dashboard running at http://localhost:${port}`);
  console.log(`📁 Project: ${projectDir}`);
  const sid = sessionId || findLatestSession();
  console.log(`📋 Session: ${sid || '(waiting for session...)'}\n`);
  startWatching();
});
