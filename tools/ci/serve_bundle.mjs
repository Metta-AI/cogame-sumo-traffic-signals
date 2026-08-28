// A four-line static file server for the built bundle, so the renderer fixture
// runs over HTTP rather than file:// — wasm streaming compilation and fetch()
// both behave differently there, and `fetch('./index.html')` (which is how the
// fixture executes the SHIPPED page rather than re-implementing it) is blocked
// on file:// outright.
//
//   node tools/ci/serve_bundle.mjs <dir> [port]
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { extname, join, normalize } from 'node:path';

const root = process.argv[2] || 'dist/static-replay-viewer';
const port = Number(process.argv[3] || 8931);
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.data': 'application/octet-stream',
  '.replay': 'application/octet-stream',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ttf': 'font/ttf'
};

createServer((request, response) => {
  let path = decodeURIComponent((request.url || '/').split('?')[0]);
  if (path === '/') path = '/index.html';
  const file = join(root, normalize(path).replace(/^(\.\.[/\\])+/, ''));
  if (!existsSync(file) || !statSync(file).isFile()) {
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('not found\n');
    return;
  }
  response.writeHead(200, {
    'content-type': TYPES[extname(file)] || 'application/octet-stream',
    'access-control-allow-origin': '*',
    'cache-control': 'no-cache'
  });
  createReadStream(file).pipe(response);
}).listen(port, '127.0.0.1', () => {
  console.log(`serving ${root} on http://127.0.0.1:${port}`);
});
