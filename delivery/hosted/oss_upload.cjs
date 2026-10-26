#!/usr/bin/env node
'use strict';
const fs = require('node:fs');

// A small ossutil-compatible adapter for hosts that already have ali-oss installed.
async function main(args) {
  const configIndex = args.indexOf('-c');
  const destination = /^oss:\/\/([a-z0-9][a-z0-9-]{1,61}[a-z0-9])\/([A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)*\/v1\/blobs\/[a-f0-9]{64})$/.exec(args[2] || '');
  if (args[0] !== 'cp' || !destination || configIndex < 0 || !args[configIndex + 1]) {
    throw new Error('Invalid artifact upload arguments');
  }
  const values = {};
  let section = '';
  for (const raw of fs.readFileSync(args[configIndex + 1], 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) section = line.slice(1, -1).toLowerCase();
    else if (section === 'credentials' && !line.startsWith('#')) {
      const index = line.indexOf('=');
      if (index > 0) values[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim();
    }
  }
  if (!values.accesskeyid || !values.accesskeysecret || !values.endpoint) {
    throw new Error('Incomplete object storage configuration');
  }
  const endpoint = new URL(values.endpoint.includes('://') ? values.endpoint : 'https://' + values.endpoint);
  if (!endpoint.hostname.endsWith('.aliyuncs.com') || endpoint.username || endpoint.password ||
      endpoint.search || endpoint.hash || endpoint.pathname !== '/') throw new Error('Invalid OSS endpoint');
  endpoint.protocol = 'https:';
  const OSS = require('ali-oss');
  const client = new OSS({ endpoint: endpoint.origin, bucket: destination[1], secure: true,
    accessKeyId: values.accesskeyid, accessKeySecret: values.accesskeysecret,
    ...(values.ststoken ? { stsToken: values.ststoken } : {}), timeout: 30000 });
  try {
    await client.put(destination[2], args[1], { headers: {
      'x-oss-forbid-overwrite': 'true',
      'Content-Type': 'application/octet-stream',
      'Cache-Control': 'public,max-age=31536000,immutable',
      ...(args[1].endsWith('.apk') ? { 'Content-Disposition': 'attachment; filename="app.apk"' } :
        args[1].endsWith('.ipa') ? { 'Content-Disposition': 'attachment; filename="app.ipa"' } : {}),
    } });
  } catch (error) {
    // The caller independently verifies the complete existing CDN content.
    if (error.code !== 'FileAlreadyExists') throw error;
  }
}

main(process.argv.slice(2)).catch(() => {
  process.stderr.write('Object storage upload failed; details withheld to protect credentials\n');
  process.exitCode = 1;
});
