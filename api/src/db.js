const { Pool } = require('pg');

let pool;

// The pool is created lazily so tests (and /api/health) never need a database.
function getPool() {
  if (!pool) {
    pool = new Pool({
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT || 5432),
      database: process.env.DB_NAME,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      // RDS Postgres enforces TLS. LAB SHORTCUT: we don't verify the server
      // certificate. In production, load the RDS CA bundle instead.
      ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
      max: 5,
    });
  }
  return pool;
}

module.exports = { getPool };
