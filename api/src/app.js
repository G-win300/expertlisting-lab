const os = require('os');
const express = require('express');
const { getPool } = require('./db');

const app = express();

const VERSION = process.env.APP_VERSION || 'dev';
const SERVED_BY = process.env.SERVED_BY || 'local';

// Liveness: used by the ALB / nginx. Deliberately does NOT touch the database,
// so a DB blip doesn't make every task look unhealthy and get replaced.
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Tells you exactly which build and which backend answered the request.
app.get('/api/info', (req, res) => {
  res.json({ version: VERSION, servedBy: SERVED_BY, host: os.hostname() });
});

app.get('/api/listings', async (req, res, next) => {
  try {
    const { rows } = await getPool().query(
      'SELECT id, title, city, listing_type, price_ngn FROM listings ORDER BY id'
    );
    res.json(rows);
  } catch (err) {
    next(err);
  }
});

// Optional CPU-burn endpoint for the autoscaling exercise. Only enabled where
// ENABLE_BURN=true (staging), never in prod.
if (process.env.ENABLE_BURN === 'true') {
  app.get('/api/burn', (req, res) => {
    const ms = Math.min(Number(req.query.ms) || 50, 500);
    const end = Date.now() + ms;
    while (Date.now() < end) { /* busy loop */ }
    res.json({ burnedMs: ms });
  });
}

app.use((err, req, res, next) => {
  console.error(JSON.stringify({ level: 'error', msg: err.message, path: req.path }));
  res.status(500).json({ error: 'internal error' });
});

module.exports = app;
