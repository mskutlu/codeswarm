/**
 * Simple test runner — no dependencies needed.
 * Tests the CRUD API endpoints.
 */
const http = require('http');

const BASE = 'http://localhost:3999';
let passed = 0;
let failed = 0;

async function request(method, path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, BASE);
    const opts = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname + url.search,
      method,
      headers: { 'Content-Type': 'application/json' }
    };
    const req = http.request(opts, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

function assert(name, condition) {
  if (condition) {
    console.log(`  ✅ ${name}`);
    passed++;
  } else {
    console.log(`  ❌ ${name}`);
    failed++;
  }
}

async function run() {
  console.log('\n🧪 Running Demo CRUD API Tests\n');

  // Health
  console.log('--- Health ---');
  const health = await request('GET', '/health');
  assert('GET /health returns 200', health.status === 200);
  assert('Health has status ok', health.body.status === 'ok');

  // TODO: Phase 1 tests — CRUD operations
  // TODO: Phase 2 tests — Validation & error handling
  // TODO: Phase 3 tests — Search & pagination

  console.log(`\n📊 Results: ${passed} passed, ${failed} failed\n`);
  process.exit(failed > 0 ? 1 : 0);
}

run().catch(e => { console.error(e); process.exit(1); });
