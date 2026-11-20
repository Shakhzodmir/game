// GLOW: keeps the district pictures of the web build between visits and between releases.
//
// The web build ships the pictures of every district but the first one as packs/<path>?v=<content hash> next to
// index.html (tools/gen_defold.py, client/packs.lua). GitHub Pages sends max-age=600 and gives EVERY file a new ETag
// at each release, so the browser's own cache would download every picture again after each release. An address
// with ?v=<hash> never changes its content: once stored here it is answered from here, with no request at all.
// Only a response whose SHA-1 matches its v= is stored (a captive portal page or a broken download never sticks);
// storing a picture drops the older versions of the same file. Anything else goes to the network untouched.
'use strict';
var CACHE = 'glow-packs-1';

self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });

function hex(buf) {
	var b = new Uint8Array(buf), s = '';
	for (var i = 0; i < b.length; i++) s += (b[i] < 16 ? '0' : '') + b[i].toString(16);
	return s;
}

async function fromNetwork(req, url, cache) {
	var res = await fetch(req);
	if (!cache || res.status !== 200) return res;
	var body = await res.arrayBuffer();
	var out = new Response(body, { status: 200, headers: { 'Content-Type': res.headers.get('Content-Type') || 'application/octet-stream' } });
	try {
		var sum = hex(await crypto.subtle.digest('SHA-1', body));
		if (sum.slice(0, url.searchParams.get('v').length) === url.searchParams.get('v')) {
			var keys = await cache.keys();
			for (var i = 0; i < keys.length; i++) {
				var k = new URL(keys[i].url);
				if (k.pathname === url.pathname && k.search !== url.search) await cache.delete(keys[i]);
			}
			await cache.put(req, out.clone());
		}
	} catch (e) { /* no storage: the picture still goes to the game */ }
	return out;
}

self.addEventListener('fetch', function (e) {
	var req = e.request;
	if (req.method !== 'GET') return;
	var url = new URL(req.url);
	if (url.pathname.indexOf('/packs/') < 0 || !url.searchParams.get('v')) return;
	e.respondWith((async function () {
		var cache = null;
		try { cache = await caches.open(CACHE); } catch (err) { cache = null; }
		if (cache) {
			var hit = await cache.match(req);
			if (hit) return hit;
		}
		return fromNetwork(req, url, cache);
	})());
});
