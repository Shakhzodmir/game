// GLOW accounts: the public identifiers of the auth provider's project (Firebase). They are NOT secrets: they
// only say which project the page talks to; who may read what is decided by the access rules of the project
// (docs/handoff/WP-10.md has the rules text). Leave the fields empty until the project exists: the game then
// runs as a guest game and says "sign-in is not available yet".
//
// Where to find the values: Firebase console -> Project settings -> General -> "Your apps" -> Web app -> Config.
// Do not put anything else here (no service-account keys, no passwords).
window.GLOW_AUTH_CONFIG = {
	apiKey: "AIzaSyAVP6x2_43pgnbrkbZabaWVLIOrWXm78uk",
	authDomain: "glow-dcd7e.firebaseapp.com",
	projectId: "glow-dcd7e",
	appId: "1:956973883845:web:a116712289c4057159ebac",

	// Google sign-in on an iPhone or iPad (web/glow_auth.js googleFlow(); docs/handoff/google-signin-ios.md). The Firebase
	// pop-up can lose its answer on the way back there, so there are other ways to ask Google. All four lines are public.
	// googleClientId / googleReturn: the web client of this project and the page Google sends the player back to
	// (web/auth_return.html). Both must be registered at Google (docs/handoff/google-signin-console-steps.md): the return
	// page as an "Authorized redirect URI" of that client, the site as an "Authorized JavaScript origin".
	googleClientId: "956973883845-ct7e77188vteg5edv7m3sgp8j8iptd5r.apps.googleusercontent.com",
	googleReturn: "https://shakhzodmir.github.io/game/auth_return.html",
	// googleIos: the way for a Safari (or Chrome...) tab; googleIosHome: for the game opened from the Home Screen icon.
	// One of "firebase" (today's way, the default), "shim", "oidc_popup", "oidc_redirect", and for the Home Screen app also
	// "no_window". Flipping a line takes effect with the next release (raise VERSION in glow_auth.js and the ?v= of the
	// script tags in web/engine_template.html together); putting "firebase" back undoes it. Desktop and Android never
	// read these lines.
	googleIos: "firebase",
	googleIosHome: "firebase"
};
