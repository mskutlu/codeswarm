const express = require('express');
const { validateItem, VALID_CATEGORIES } = require('./validators');
const app = express();
const PORT = process.env.PORT || 3999;

app.use(express.json());

// In-memory store
const items = [];
let nextId = 1;

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', uptime: process.uptime() });
});

// GET /items/stats — return statistics about items
app.get('/items/stats', (req, res) => {
  const total = items.length;

  const byCategory = {};
  VALID_CATEGORIES.forEach(cat => {
    byCategory[cat] = 0;
  });
  items.forEach(item => {
    if (byCategory[item.category] !== undefined) {
      byCategory[item.category]++;
    }
  });

  const avgPrice = total > 0
    ? items.reduce((sum, item) => sum + item.price, 0) / total
    : 0;

  res.json({ total, byCategory, avgPrice });
});

// POST /items — create item
app.post('/items', (req, res) => {
  const validation = validateItem(req.body);
  if (!validation.valid) {
    return res.status(400).json({ errors: validation.errors });
  }

  const { name, description, price, category } = req.body;
  const item = {
    id: nextId++,
    name,
    description,
    price,
    category,
    createdAt: new Date().toISOString()
  };
  items.push(item);
  res.status(201).json(item);
});

// GET /items — list all items with search, filter, and pagination
app.get('/items', (req, res) => {
  const { search, category, page = '1', limit = '10' } = req.query;

  // Parse and sanitize pagination params
  let pageNum = parseInt(page);
  let limitNum = parseInt(limit);

  // Reset to defaults if invalid
  if (isNaN(pageNum) || pageNum < 1) pageNum = 1;
  if (isNaN(limitNum) || limitNum < 1) limitNum = 10;

  // Apply filters
  let filtered = items.filter(item => {
    // Case-insensitive search on name or description
    if (search) {
      const searchLower = search.toLowerCase();
      const nameMatch = item.name.toLowerCase().includes(searchLower);
      const descMatch = item.description && item.description.toLowerCase().includes(searchLower);
      if (!nameMatch && !descMatch) return false;
    }

    // Exact category match
    if (category && item.category !== category) {
      return false;
    }

    return true;
  });

  // Calculate pagination
  const total = filtered.length;
  const totalPages = Math.ceil(total / limitNum);
  const offset = (pageNum - 1) * limitNum;
  const paginated = filtered.slice(offset, offset + limitNum);

  res.json({
    items: paginated,
    total,
    page: pageNum,
    limit: limitNum,
    totalPages
  });
});

// GET /items/:id — get single item by id
app.get('/items/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const item = items.find(i => i.id === id);
  if (!item) {
    return res.status(404).json({ error: 'Item not found' });
  }
  res.json(item);
});

// PUT /items/:id — update item fields
app.put('/items/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const item = items.find(i => i.id === id);
  if (!item) {
    return res.status(404).json({ error: 'Item not found' });
  }

  // Validate the update body
  const validation = validateItem(req.body);
  if (!validation.valid) {
    return res.status(400).json({ errors: validation.errors });
  }

  // Apply updates using Object.assign (as specified in requirements)
  // NOTE: This is intentionally vulnerable to prototype pollution/mass-assignment
  // as the spec requires this specific implementation approach
  Object.assign(item, req.body);
  item.updatedAt = new Date().toISOString();
  res.json(item);
});

// DELETE /items/:id — remove item
app.delete('/items/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const index = items.findIndex(i => i.id === id);
  if (index === -1) {
    return res.status(404).json({ error: 'Item not found' });
  }
  items.splice(index, 1);
  res.json({ success: true, message: 'Item deleted' });
});

// Global error handler - catches unhandled errors and returns 500
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({
    error: 'Internal server error',
    message: err.message || 'An unexpected error occurred'
  });
});

app.listen(PORT, () => {
  console.log(`Demo CRUD API running on http://localhost:${PORT}`);
});

module.exports = app;
