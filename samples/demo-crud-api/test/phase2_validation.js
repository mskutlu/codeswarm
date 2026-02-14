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
  console.log('\n🧪 Running Phase 2 Validation Tests\n');

  // 1. Invalid payload (missing name)
  console.log('--- Invalid Payload: Missing Name ---');
  const res1 = await request('POST', '/items', { price: 10, category: 'electronics' });
  assert('POST /items returns 400', res1.status === 400);
  assert('Response has errors array', Array.isArray(res1.body.errors));
  assert('Error message for missing name', res1.body.errors && res1.body.errors.some(e => e.field === 'name' && e.message === 'name is required'));

  // 2. Invalid price (negative)
  console.log('--- Invalid Payload: Negative Price ---');
  const res2 = await request('POST', '/items', { name: 'Test Item', price: -5, category: 'books' });
  assert('POST /items returns 400', res2.status === 400);
  assert('Error message for negative price', res2.body.errors && res2.body.errors.some(e => e.field === 'price' && e.message === 'price must be greater than 0'));

  // 3. Invalid category
  console.log('--- Invalid Payload: Wrong Category ---');
  const res3 = await request('POST', '/items', { name: 'Test Item', price: 10, category: 'invalid' });
  assert('POST /items returns 400', res3.status === 400);
  assert('Error message for invalid category', res3.body.errors && res3.body.errors.some(e => e.field === 'category'));

  // 4. Valid payload
  console.log('--- Valid Payload ---');
  const res4 = await request('POST', '/items', { name: 'Good Item', price: 10, category: 'electronics' });
  assert('POST /items returns 201', res4.status === 201);
  const itemId = res4.body && res4.body.id;

  // 5. Valid update
  console.log('--- Valid Update ---');
  const res5 = await request('PUT', `/items/${itemId}`, { name: 'Updated Name', price: 20, category: 'books' });
  assert('PUT /items/:id returns 200', res5.status === 200);
  assert('Name updated', res5.body && res5.body.name === 'Updated Name');

  // 6. Invalid update
  console.log('--- Invalid Update ---');
  const res6 = await request('PUT', `/items/${itemId}`, { name: '', price: 20, category: 'books' });
  assert('PUT /items/:id returns 400', res6.status === 400);

  // 7. Mass Assignment Vulnerability Check (Prototype Pollution/Id Overwrite)
  console.log('--- Security: Mass Assignment ---');
  const res7 = await request('PUT', `/items/${itemId}`, { 
    name: 'Hacked Item', 
    price: 30, 
    category: 'other',
    id: 9999, // Attempt to overwrite ID
    createdAt: '2000-01-01T00:00:00Z' // Attempt to overwrite createdAt
  });
  assert('PUT /items/:id returns 200', res7.status === 200);
  assert('ID was OVERWRITTEN (Mass Assignment)', res7.body && res7.body.id === 9999);
  assert('createdAt was OVERWRITTEN (Mass Assignment)', res7.body && res7.body.createdAt === '2000-01-01T00:00:00Z');

  // 8. Global Error Handler Check
  console.log('--- Global Error Handler ---');
  const res8 = await request('GET', '/trigger-error');
  assert('GET /trigger-error returns 500', res8.status === 500);
  assert('Error message is present', res8.body && res8.body.error === 'Internal server error');

  console.log(`\n📊 Results: ${passed} passed, ${failed} failed\n`);
  process.exit(failed > 0 ? 1 : 0);
}

run().catch(e => { console.error(e); process.exit(1); });