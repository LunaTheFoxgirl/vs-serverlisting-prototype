import std.stdio;
import vibe.d;
import vibe.crypto.cryptorand;
import vibe.data.serialization : ignore;
import std.base64;

/// How many minutes before a server will be removed.
enum TIMEOUT_TIME = 5;

/// A registered playstyle
struct Playstyle {
	/// Id of playstyle
	string id;

	/// language code
	string langCode;
}

/// A index in the server listing.
struct ServerIndex {
public:
	/// Name of the server
	string serverName;

	/// The IP address of the server (including port)
	string serverIP;

	/// The playstyle
	Playstyle playstyle;

	/// the amount of players that can maximum be connected to the server.
	size_t maxPlayers;

	/// The amount of players currently playing
	size_t players;

	/// The version of Vintage Story the server uses
	string gameVersion;

	/// Reserved: Logo for the server in the listing
	@optional
	string serverLogo;

	/// When the server was last verified to be online, as UNIX time
	long lastVerified;

	/// Has password?
	bool hasPassword;
}

@trusted string getTargetIP(string originIP, ushort port) {
	return "%s:%d".format(originIP.stripConnectionPort, port);
}

@trusted ServerIndex* serverIndexFromRequest(RegisterRequest request, string targetIP) {
	ServerIndex* index = new ServerIndex();
	index.maxPlayers = request.maxPlayers;
	index.serverName = request.name;
	index.serverLogo = request.icon;
	index.playstyle = request.playstyle;
	index.hasPassword = request.hasPassword;
	index.gameVersion = request.gameVersion;
	index.serverIP = targetIP;
	index.lastVerified = nowUNIXTime();
	return index;
}

/// wrapper for the JSON input data.
struct RegisterRequest {
	/// Port the server is on
	ushort port;

	/// Name to be displayed
	string name;

	/// Reserved: Icon of the server
	@optional
	string icon;

	/// The registered playstyle
	Playstyle playstyle;

	/// Max number of clients.
	size_t maxPlayers;

	/// Version of the game
	string gameVersion;

	/// Has password?
	bool hasPassword;
}

struct KeepAlivePacket {
	/// Token
	string token;

	/// The active player count
	size_t players;
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
	@bodyParam("keepalive")
	@path("/heartbeat")
	@safe
	string keepAlive(KeepAlivePacket keepalive);

	@method(HTTPMethod.POST)
	@path("/unregister")
	@bodyParam("token")
	string unregisterServer(string token);

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

		string token = newKey();
		string targetIP = getTargetIP(request.peer(), json.port);

		// If the server is already registered for some reason, use its token
		foreach(extoken, server; servers) {
			if (server.serverIP == targetIP) {
				token = extoken;
				break;
			}
		}

		// Assign the server to the token using request to get the calling IP address.
		servers[token] = serverIndexFromRequest(json, targetIP);

		// Rebuild the server cache and return the new token.
		rebuildCache();
		return token;
	}

	/// See interface for info
	string keepAlive(KeepAlivePacket keepalive) {
		// If the token is not present in the server dictionary, report it back.
		if (keepalive.token !in servers) return "invalid";

		// Do cleanup and update the heartbeat time.
		cleanup();
		if (keepalive.token !in servers) return "timeout";

		servers[keepalive.token].players = keepalive.players;
		servers[keepalive.token].lastVerified = nowUNIXTime();
		return "ok";
	}

	string unregisterServer(string token) {
		if (token !in servers) return "invalid";
		servers[token].lastVerified = 0;
		cleanup();
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
	version(linux) {
		import etc.linux.memoryerror;
		static if (is(typeof(registerMemoryErrorHandler)))
			registerMemoryErrorHandler();
	}

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