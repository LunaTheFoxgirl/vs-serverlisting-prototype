import std.stdio;
import vibe.d;
import vibe.crypto.cryptorand;
import std.base64;

/// How many minutes before a server will be removed.
enum TIMEOUT_TIME = 5;

/// A index in the server listing.
struct ServerIndex {
public:
	/// Name of the server
	string serverName;

	/// The IP address of the server
	string serverIP;

	/// Reserved: Logo for the server in the listing
	string serverLogo;

	/// When the server was last verified to be online, as UNIX time
	long lastVerified;
}

/// wrapper for the JSON input data.
struct RegisterRequest {
	ushort port;

	string name;

	string icon;
}

/// Small helper that allows getting the HTTPServerRequest directly
@safe HTTPServerRequest getRequest(HTTPServerRequest req, HTTPServerResponse res) { 
	return req; 
}

/// Interface of the listing API.
@path("/api/v1/servers")
interface IListingAPI {

	/// Verify that the service is running
	@method(HTTPMethod.GET)
	@path("/verify")
	@safe
	string verifyRunning();

	/// Register server
	/// use @before to fetch the backend request so we can get the IP directly.
	/// use @bodyParam to mark the json parameter as the JSON body
	@method(HTTPMethod.POST)
	@before!getRequest("request")
	@bodyParam("json")
	@path("/register")
	@safe
	string registerServer(RegisterRequest json, HTTPServerRequest request);

	/// Heartbeat function, this should be called in an interval lower than TIMEOUT_TIME, but not too fast either.
	/// If a server fails to call heartbeat in time, i'll be removed from the list and "invalid" will be returned instead.
	@method(HTTPMethod.POST)
	@path("/heartbeat")
	@safe
	string keepAlive(string token);

	/// Gets the server list
	@method(HTTPMethod.GET)
	@path("/list")
	@safe
	ServerIndex*[] getServers();
}

/// Gets the current time in UNIX time
@trusted long nowUNIXTime() {
	return Clock.currStdTime();
}

/// strips away the port which a connection peer used
@trusted string stripConnectionPort(string ip) {
	size_t offset = 1;

	// NOTE: $ refers to the end of an array, we're slicing it up here.
	while (ip[$-(offset)] != ':') offset++;
	return ip[0..$-offset];
}

/// Implementation
class ListingAPI : IListingAPI {
private:
	// An array cache of the servers
	ServerIndex*[] serverCache;

	// the backend list which stores the actual servers.
	ServerIndex*[string] servers;
	RandomNumberStream random;

	/// Creates a new key via a cryptographically secure random number
	/// returns it in base64
	@trusted string newKey() {
		ubyte[64] buffer;
		random.read(buffer);
		return Base64.encode(buffer);
	}

	/// Cleanup unresponsive servers.
	@trusted void cleanup() {
		long currentTime = nowUNIXTime();

		size_t removed = 0;

		// Gets TIMEOUT_TIME minutes as hnsecs, the resolution which currStdTime uses.
		long checkAgainst = (TIMEOUT_TIME.minutes).total!"hnsecs";
		foreach(token, value; servers) {

			/// If the server hasn't responded for TIMEOUT_TIME minutes, remove it from the list.
			if (currentTime-value.lastVerified > checkAgainst) {
				servers.remove(token);
				removed++;
			}
		}

		// Rebuild the server cache if there has been removed any servers.
		if (removed > 0) rebuildCache();
	}

	@trusted void rebuildCache() {
		// clear the list and make a new one with the same amount of indexes as the actual list
		serverCache = new ServerIndex*[servers.length];

		// Fill it out
		size_t i = 0;
		foreach(token, value; servers) {
			serverCache[i++] = value;
		}
	}

public:

	/// Constructor
	this() {
		random = secureRNG();
	}

	/// See interface for info
	string verifyRunning() {
		return "ok";
	}

	/// See interface for info
	string registerServer(RegisterRequest json, HTTPServerRequest request) {

		// Create a new token and assign the server to it using request to get the calling IP address.
		string token = newKey();
		servers[token] = new ServerIndex(json.name, "%s:%d".format(request.peer().stripConnectionPort, json.port), json.icon, nowUNIXTime());

		// Rebuild the server cache and return the new token.
		rebuildCache();
		return token;
	}

	/// See interface for info
	string keepAlive(string token) {
		// If the token is not present in the server dictionary, report it back.
		if (token !in servers) return "invalid";

		// Do cleanup and update the heartbeat time.
		cleanup();
		servers[token].lastVerified = nowUNIXTime();
		return "ok";
	}

	/// See interface for info
	ServerIndex*[] getServers() {
		cleanup();
		return serverCache;
	}
}


void main() {
	/// Throw useful exceptions on Linux if a memory/segfault happens
	import etc.linux.memoryerror;
	static if (is(typeof(registerMemoryErrorHandler)))
		registerMemoryErrorHandler();

	/// Run the core server loop
	runApplication();
}

/// This constructor is run at program launch, useful since vibe.d is multithreaded
shared static this() {
	URLRouter router = new URLRouter();
	router.registerRestInterface!IListingAPI(new ListingAPI());

	auto settings = new HTTPServerSettings();
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	settings.sessionStore = new MemorySessionStore;

	listenHTTP(settings, router);
}