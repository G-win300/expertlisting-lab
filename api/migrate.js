// Minimal migration runner: applies migrations/*.sql in filename order,
// each in its own transaction, and records what ran in schema_migrations.
// An advisory lock makes concurrent runs safe (only one proceeds at a time).
const fs = require('fs');
const path = require('path');
const { getPool } = require('./src/db');

const LOCK_ID = 424242;

async function main() {
  const pool = getPool();
  const client = await pool.connect();
  try {
    await client.query('SELECT pg_advisory_lock($1)', [LOCK_ID]);
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version    TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )`);

    const dir = path.join(__dirname, 'migrations');
    const files = fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
    const { rows } = await client.query('SELECT version FROM schema_migrations');
    const applied = new Set(rows.map((r) => r.version));

    for (const file of files) {
      if (applied.has(file)) continue;
      console.log(`applying ${file}`);
      await client.query('BEGIN');
      try {
        await client.query(fs.readFileSync(path.join(dir, file), 'utf8'));
        await client.query('INSERT INTO schema_migrations (version) VALUES ($1)', [file]);
        await client.query('COMMIT');
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`${file} failed: ${err.message}`);
      }
    }
    console.log('migrations complete');
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [LOCK_ID]).catch(() => {});
    client.release();
    await pool.end();
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
