// tunnel-pico-bot — Node supervisor flavor.
// For platforms that start the app with `node index.js` (Galaxy, Pterodactyl
// Node eggs). Two jobs in ONE Node process:
//   1. Placeholder HTTP server on $PORT answering "ok" — something for
//      platform health checks / port expectations to hit. The tunnel itself
//      is outbound-only and does not need this server.
//   2. Supervise pico.sh (xray + cloudflared); restart it if it exits.
// Zero dependencies, deliberately tiny. Where the platform can run a shell
// script directly, skip this file and run pico.sh alone (saves ~30 MB).
const { spawn } = require('child_process');
const http = require('http');

const port = parseInt(process.env.PORT || '3000', 10);
const srv = http.createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'text/plain' });
  res.end('ok\n');
});
srv.on('error', (e) => {
  console.log(`[pico] web placeholder not started (${e.code || e.message})`);
});
srv.listen(port, '0.0.0.0', () => console.log(`[pico] web placeholder on :${port}`));

let child = null;
let stopping = false;

function start() {
  child = spawn('sh', ['pico.sh'], { stdio: 'inherit' });
  child.on('exit', (code, signal) => {
    console.log(`[pico] pico.sh exited (code=${code}, signal=${signal})`);
    if (!stopping) {
      console.log('[pico] restarting in 5s');
      setTimeout(start, 5000);
    }
  });
  child.on('error', (err) => {
    console.error('[pico] failed to spawn pico.sh:', err);
    if (!stopping) setTimeout(start, 5000);
  });
}

process.on('SIGTERM', () => { stopping = true; if (child) child.kill('SIGTERM'); });
process.on('SIGINT', () => { stopping = true; if (child) child.kill('SIGINT'); });

start();
