'use strict';
const http = require('node:http');
const { Transform } = require('node:stream');

// Mount before body parsers; authentication remains in the isolated service.
module.exports = function hotfixProxy(port) {
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid hotfix port');
  return (request, response) => {
    const target = new URL(request.url, 'http://127.0.0.1');
    const allowed = request.method === 'GET'
      ? /^\/(baselines|uploads|stats|check|withdrawals|retention|blobs\/[a-f0-9]{64})$/
      : request.method === 'POST' ? /^\/(baselines(?:\/[a-f0-9]{64}\/(?:finish|delete|restore|chunks\/[0-9]{1,4}))?|patch-numbers|uploads(?:\/[a-f0-9]{64}\/[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\/(?:delete|restore))?|retention\/(?:register|lease|reconcile|cleanup)|activate|reports)$/ : /$^/;
    if (!request.url.startsWith('/') || request.url.startsWith('//') ||
        target.origin !== 'http://127.0.0.1' || !allowed.test(target.pathname)) {
      response.statusCode = 404;
      response.end();
      return;
    }
    const limit = 16 * 1024 * 1024;
    if (Number(request.headers['content-length'] || 0) > limit) {
      response.statusCode = 413;
      response.end();
      return;
    }
    const headers = {};
    for (const name of ['authorization', 'content-type', 'content-length', 'accept']) {
      if (request.headers[name]) headers[name] = request.headers[name];
    }
    const upstream = http.request({ host: '127.0.0.1', port,
      path: '/v1' + target.pathname + target.search, method: request.method, headers }, incoming => {
      response.statusCode = incoming.statusCode;
      for (const name of ['content-type', 'content-length', 'cache-control']) {
        if (incoming.headers[name]) response.setHeader(name, incoming.headers[name]);
      }
      incoming.on('error', () => response.destroy());
      incoming.pipe(response);
    });
    upstream.setTimeout(120000, () => upstream.destroy());
    upstream.on('error', () => {
      if (!response.headersSent) {
        response.statusCode = 503;
        response.setHeader('Content-Type', 'application/json');
        response.end('{"error":"Hotfix service unavailable"}');
      } else response.destroy();
    });
    let bytes = 0;
    const bounded = new Transform({ transform(chunk, encoding, done) {
      bytes += chunk.length;
      if (bytes > limit) {
        response.statusCode = 413;
        response.end();
        upstream.destroy();
        done(new Error('Request too large'));
      } else done(null, chunk);
    } });
    bounded.on('error', () => upstream.destroy());
    request.on('aborted', () => upstream.destroy());
    request.on('error', () => upstream.destroy());
    response.on('close', () => upstream.destroy());
    request.pipe(bounded).pipe(upstream);
  };
};
