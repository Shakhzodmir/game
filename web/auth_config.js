// GLOW accounts: the public identifiers of the auth provider's project (Firebase). They are NOT secrets: they
// only say which project the page talks to; who may read what is decided by the access rules of the project
// (docs/handoff/WP-10.md has the rules text). Leave the fields empty until the project exists: the game then
// runs as a guest game and says "sign-in is not available yet".
//
// Where to find the values: Firebase console -> Project settings -> General -> "Your apps" -> Web app -> Config.
// Do not put anything else here (no service-account keys, no passwords).
window.GLOW_AUTH_CONFIG = {
	apiKey: "",
	authDomain: "",
	projectId: "",
	appId: ""
};
