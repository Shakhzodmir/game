// Live check of the "forgot password" operation of web/glow_auth.js against the real Firebase project of
// web/auth_config.js, in Chrome through playwright-core. No sign-in, no account: it only asks Firebase to send a
// reset letter, and only to addresses like nobody<random>@example.invalid (a reserved domain: nothing can arrive,
// nobody can be reached). Never point it at a real address.
//   node tools/qa/reset_e2e.mjs <base url that serves web/, e.g. http://localhost:18733>
// PLAYWRIGHT_CORE may name the playwright-core module to import (default: playwright-core from node_modules).
import crypto from "node:crypto";

const base = process.argv[2];
if (!base || !/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(base)) {
	console.error("usage: node tools/qa/reset_e2e.mjs http://localhost:<port>   (a local server of the web/ folder)");
	process.exit(2);
}
const { chromium } = await import(process.env.PLAYWRIGHT_CORE || "playwright-core");
const browser = await chromium.launch({ channel: "chrome" });
const context = await browser.newContext({ viewport: { width: 540, height: 960 } });
const page = await context.newPage();
const logs = [];
page.on("console", (m) => logs.push(m.type() + ": " + m.text().slice(0, 200)));
await page.route(base + "/e2e.html", (r) => r.fulfill({ contentType: "text/html",
	body: '<!doctype html><html><body><canvas id="canvas"></canvas><script src="auth_config.js"></script><script src="glow_auth.js"></script></body></html>' }));

// what Firebase was asked: the letter's language travels in the X-Firebase-Locale header
const sent = [];
page.on("request", (req) => {
	if (/accounts:sendOobCode/.test(req.url())) {
		let body = {};
		try { body = JSON.parse(req.postData() || "{}"); } catch (e) { /* not JSON */ }
		sent.push({ type: body.requestType, locale: req.headers()["x-firebase-locale"] || "" });
	}
});

await page.goto(base + "/e2e.html");
const configured = await page.evaluate(() => window.glowAuth.configured);
console.log("configured:", configured);

let n = 0;
async function op(name, args, fill) {
	const cid = "c" + (++n);
	const r = await page.evaluate(([cid, name, args]) => window.glowAuth.call(cid, name, args), [cid, name, args]);
	if (r !== "ok") return { ok: false, reason: "call:" + r };
	if (fill) await fill();
	for (let i = 0; i < 120; i++) {
		const out = await page.evaluate(() => window.glowAuth.poll());
		for (const line of out.split("\n").filter(Boolean)) {
			const [lid, ok, reason, fields] = line.split("|");
			if (lid === cid) return { ok: ok === "1", reason, fields };
		}
		await page.waitForTimeout(250);
	}
	return { ok: false, reason: "timeout" };
}
const labels = ["title", "Forgot password?", "email", "E-mail", "submit", "Send", "cancel", "Cancel",
	"err_email", "This does not look like an e-mail address"];
const nobody = () => "nobody" + crypto.randomBytes(5).toString("hex") + "@example.invalid";
async function fillEmail(value, submit = true) {
	await page.waitForSelector("form input[name=email]", { timeout: 20000 });
	await page.fill("input[name=email]", value);
	if (submit) await page.click("button[type=submit]");
}

const steps = [];
const rec = (name, pass, extra) => { steps.push([name, pass ? "OK" : "FAIL", extra || ""]); return pass; };

// 1. the form refuses junk and an ID account's inner address without asking Firebase
{
	const before = sent.length;
	const p = op("reset_password", ["en", ...labels], async () => {
		await fillEmail("not an address");
		rec("form refuses 'not an address'", (await page.textContent("form div:nth-last-child(2)")).includes("e-mail address"));
		await page.fill("input[name=email]", "someone@id.glow.invalid");
		await page.click("button[type=submit]");
		rec("form refuses an ID account's inner address", (await page.textContent("form div:nth-last-child(2)")).includes("e-mail address"));
		await page.click("button[type=button]"); // cancel
	});
	const r = await p;
	rec("cancelled form answers 'cancelled'", !r.ok && r.reason === "cancelled", JSON.stringify(r));
	rec("nothing was sent to Firebase by the refused input", sent.length === before);
}

// 2. one real request per language, each to a fresh nobody...@example.invalid
for (const lang of ["en", "ru", "ko"]) {
	const r = await op("reset_password", [lang, ...labels], () => fillEmail(nobody()));
	rec("reset_password (" + lang + ") answers 1", r.ok === true, JSON.stringify(r));
	const last = sent[sent.length - 1];
	rec("the letter's language header is " + lang, !!last && last.type === "PASSWORD_RESET" && last.locale === lang, JSON.stringify(last));
}

// 3. no network: a readable error (reason 'offline'), not a hang
await context.setOffline(true);
{
	const r = await op("reset_password", ["en", ...labels], () => fillEmail(nobody()));
	rec("network off: reason is 'offline'", !r.ok && r.reason === "offline", JSON.stringify(r));
}
await context.setOffline(false);

for (const [name, res, extra] of steps) console.log(res.padEnd(5), name, res === "FAIL" ? extra : "");
console.log("firebase requests seen:", sent.length);
const bad = logs.filter((l) => /error/i.test(l)).slice(0, 6);
if (bad.length) console.log("console errors:", bad);
await browser.close();
process.exit(steps.some((s) => s[1] === "FAIL") ? 1 : 0);
