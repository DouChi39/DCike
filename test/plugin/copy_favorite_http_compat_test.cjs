// Run with node --test test/plugin/copy_favorite_http_compat_test.cjs.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.resolve(__dirname,
  '../../lib/plugin/utils/plugin_bundle_compat.dart'), 'utf8');
const script = source.match(/const _copyFavoriteHttpCompatibility = r'''([\s\S]*?)''';/)[1];

function runtime() {
  const requests = [];
  const context = vm.createContext({ Request, Headers, URLSearchParams,
    fetch: async (input, init) => {
      const request = input instanceof Request && !init ? input : new Request(input, init);
      requests.push({ method: request.method, url: request.url,
        contentType: request.headers.get('content-type'),
        authorization: request.headers.get('authorization'), body: await request.text() });
      return { ok: true };
    },
  });
  vm.runInContext(script, context);
  return { context, requests };
}

test('fixes the exact Copy favorite request made by ky', async () => {
  const { context, requests } = runtime();
  await context.fetch(new Request('https://example.invalid/api/v3/member/collect/comic?platform=1', {
    method: 'POST', headers: { authorization: 'Token test-session' },
    body: 'comic_id=comic-123&is_collect=1',
  }));
  assert.match(requests[0].contentType, /^application\/x-www-form-urlencoded/);
  assert.equal(requests[0].authorization, 'Token test-session');
  assert.equal(requests[0].body, 'comic_id=comic-123&is_collect=1');
});

test('preserves other endpoints, JSON requests and unrelated text bodies', async () => {
  const { context, requests } = runtime();
  for (const [url, init] of [
    ['https://example.invalid/login', { method: 'POST', body: 'username=x' }],
    ['https://example.invalid/member/collect/comic', { method: 'POST',
      headers: { 'content-type': 'application/json' }, body: '{"comic_id":"123"}' }],
    ['https://example.invalid/member/collect/comic', { method: 'POST', body: 'plain text' }],
    ['https://example.invalid/member/collect/comics', { method: 'DELETE',
      headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'ids=1' }],
  ]) await context.fetch(url, init);
  assert.equal(requests[0].contentType, 'text/plain;charset=UTF-8');
  assert.equal(requests[1].contentType, 'application/json');
  assert.equal(requests[2].contentType, 'text/plain;charset=UTF-8');
  assert.equal(requests[3].method, 'DELETE');
  assert.equal(requests[3].body, 'ids=1');
});

test('installing compatibility twice still sends one request', async () => {
  const { context, requests } = runtime();
  vm.runInContext(script, context);
  await context.fetch('https://example.invalid/member/collect/comic', {
    method: 'POST', body: 'comic_id=123&is_collect=1',
  });
  assert.equal(requests.length, 1);
});
