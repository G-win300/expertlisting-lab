const app = require('./app');

const port = Number(process.env.PORT || 3000);
const server = app.listen(port, () => {
  console.log(JSON.stringify({ level: 'info', msg: 'api listening', port, version: process.env.APP_VERSION || 'dev' }));
});

// ECS sends SIGTERM before stopping a task during a rolling deploy.
// Stop accepting new connections and let in-flight requests finish.
process.on('SIGTERM', () => {
  console.log(JSON.stringify({ level: 'info', msg: 'SIGTERM received, draining' }));
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 25000).unref();
});
