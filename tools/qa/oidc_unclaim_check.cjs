const G = require(require("path").join(__dirname, "..", "..", "web", "glow_oidc.js"));
function store() { const m = new Map(); return { getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k), key: i => [...m.keys()][i], get length() { return m.size; } }; }
const env = { localStorage: store(), sessionStorage: store(), clock: () => 1000 };
const k = G.keysFor("t");
const rec = { s: "pg.abcdefgh12", r: "rawnonce", t: 1, m: "w" };
env.sessionStorage.setItem(k.pend, JSON.stringify(rec));
let fails = 0; const ck = (ok, w) => { if (!ok) { fails++; console.log("FAIL", w); } };
ck(G.claim("t", rec.s, env, { by: "A" }) !== null, "A claims");
ck(G.claim("t", rec.s, env, { by: "B" }) === null, "B refused while A holds");
ck(G.unclaim("t", rec.s, env, { by: "B" }) === false, "B cannot release A's claim");
ck(G.claim("t", rec.s, env, { by: "B" }) === null, "still refused");
ck(G.unclaim("t", rec.s, env, { by: "A" }) === true, "A releases");
ck(G.claim("t", rec.s, env, { by: "B" }) !== null, "B claims at once after A is gone");
ck(G.unclaim("t", "pg.nothere1234", env, { by: "A" }) === false, "no attempt: false");
console.log(fails ? "unclaim: " + fails + " failed" : "unclaim check: ok");
process.exit(fails ? 1 : 0);
