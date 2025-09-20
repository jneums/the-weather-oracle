import Result "mo:base/Result";
import Text "mo:base/Text";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Nat "mo:base/Nat";
import Error "mo:base/Error";
import Float "mo:base/Float";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Char "mo:base/Char";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";

import HttpTypes "mo:http-types";
import Map "mo:map/Map";
import Json "mo:json";

import AuthCleanup "mo:mcp-motoko-sdk/auth/Cleanup";
import AuthState "mo:mcp-motoko-sdk/auth/State";
import AuthTypes "mo:mcp-motoko-sdk/auth/Types";

import Mcp "mo:mcp-motoko-sdk/mcp/Mcp";
import McpTypes "mo:mcp-motoko-sdk/mcp/Types";
import HttpHandler "mo:mcp-motoko-sdk/mcp/HttpHandler";
import Cleanup "mo:mcp-motoko-sdk/mcp/Cleanup";
import State "mo:mcp-motoko-sdk/mcp/State";
import Payments "mo:mcp-motoko-sdk/mcp/Payments";
import HttpAssets "mo:mcp-motoko-sdk/mcp/HttpAssets";
import Beacon "mo:mcp-motoko-sdk/mcp/Beacon";
import ApiKey "mo:mcp-motoko-sdk/auth/ApiKey";

import SrvTypes "mo:mcp-motoko-sdk/server/Types";

import IC "mo:ic";
import { ic } "mo:ic";

shared ({ caller = deployer }) persistent actor class McpServer(
  args : ?{
    owner : ?Principal;
  }
) = self {

  // The canister owner, who can manage treasury funds.
  // Defaults to the deployer if not specified.
  var owner : Principal = Option.get(do ? { args!.owner! }, deployer);
  var visual_crossing_api_key : ?Text = null;

  // A reasonable amount of cycles for a single HTTPS GET request.
  let HTTPS_OUTCALL_CYCLES : Nat = 30_000_000_000; // 30B cycles

  // State for certified HTTP assets (like /.well-known/...)
  var stable_http_assets : HttpAssets.StableEntries = [];
  transient let http_assets = HttpAssets.init(stable_http_assets);

  // Resource contents stored in memory for simplicity.
  // In a real application these would probably be uploaded or user generated.
  var resourceContents = [
    ("file:///README.md", "# The Weather Oracle\n\nWelcome to The Weather Oracle! This project provides accurate and up-to-date weather forecasts using advanced machine learning algorithms."),
  ];

  // The application context that holds our state.
  var appContext : McpTypes.AppContext = State.init(resourceContents);

  // =================================================================================
  // --- OPT-IN: MONETIZATION & AUTHENTICATION ---
  // To enable paid tools, uncomment the following `authContext` initialization.
  // By default, it is `null`, and all tools are public.
  // Set the payment details in each tool definition to require payment.
  // See the README for more details.
  // =================================================================================

  transient let authContext : ?AuthTypes.AuthContext = null;

  // --- UNCOMMENT THIS BLOCK TO ENABLE AUTHENTICATION ---

  // let issuerUrl = "https://bfggx-7yaaa-aaaai-q32gq-cai.icp0.io";
  // let allowanceUrl = "https://prometheusprotocol.org/connections";
  // let requiredScopes = ["openid"];

  // //function to transform the response for jwks client
  // public query func transformJwksResponse({
  //   context : Blob;
  //   response : IC.HttpRequestResult;
  // }) : async IC.HttpRequestResult {
  //   {
  //     response with headers = []; // not intersted in the headers
  //   };
  // };

  // // Initialize the auth context with the issuer URL and required scopes.
  // transient let authContext : ?AuthTypes.AuthContext = ?AuthState.init(
  //   Principal.fromActor(self),
  //   issuerUrl,
  //   requiredScopes,
  //   transformJwksResponse,
  // );

  // --- END OF AUTHENTICATION BLOCK ---

  // =================================================================================
  // --- OPT-IN: USAGE ANALYTICS (BEACON) ---
  // To enable anonymous usage analytics, uncomment the `beaconContext` initialization.
  // This helps the Prometheus Protocol DAO understand ecosystem growth.
  // =================================================================================

  // transient let beaconContext : ?Beacon.BeaconContext = null;

  // --- UNCOMMENT THIS BLOCK TO ENABLE THE BEACON ---

  let beaconCanisterId = Principal.fromText("m63pw-fqaaa-aaaai-q33pa-cai");
  transient let beaconContext : ?Beacon.BeaconContext = ?Beacon.init(
    beaconCanisterId, // Public beacon canister ID
    ?(15 * 60), // Send a beacon every 15 minutes
  );

  // --- END OF BEACON BLOCK ---

  // This block contains all necessary functions for URL encoding.
  // It is self-contained and has no external dependencies.
  private func byteToHex(byte : Nat8) : Text {
    let n = Nat8.toNat(byte);
    let high = n / 16;
    let low = n % 16;

    func nybbleToChar(nybble : Nat) : Char {
      if (nybble < 10) {
        return Char.fromNat32(Char.toNat32('0') + Nat32.fromNat(nybble));
      } else {
        return Char.fromNat32(Char.toNat32('A') + Nat32.fromNat(nybble) - 10);
      };
    };

    return Char.toText(nybbleToChar(high)) # Char.toText(nybbleToChar(low));
  };

  // This is the corrected version of the function you provided.
  // It is safe and robust for URL encoding.
  private func encodeURIComponent(t : Text) : Text {
    func is_safe(c : Char) : Bool {
      let code = Char.toNat32(c);
      // Corrected the logical comparisons (e.g., code >= 97)
      return (code >= 97 and code <= 122) or // a-z
      (code >= 65 and code <= 90) or // A-Z
      (code >= 48 and code <= 57) or // 0-9
      (code == 45 or code == 95 or code == 46 or code == 126); // - _ . ~
    };

    var result = "";
    for (c in t.chars()) {
      if (is_safe(c)) {
        result := result # Char.toText(c);
      } else {
        // This is the robust way to encode non-safe characters.
        // 1. Convert the character to its UTF-8 bytes.
        let utf8_blob = Text.encodeUtf8(Char.toText(c));
        // 2. Convert each byte to its two-digit hex representation.
        for (byte in Blob.toArray(utf8_blob).vals()) {
          result := result # "%" # byteToHex(byte);
        };
      };
    };
    return result;
  };

  // --- Timers ---
  Cleanup.startCleanupTimer<system>(appContext);

  // The AuthCleanup timer only needs to run if authentication is enabled.
  switch (authContext) {
    case (?ctx) { AuthCleanup.startCleanupTimer<system>(ctx) };
    case (null) { Debug.print("Authentication is disabled.") };
  };

  // The Beacon timer only needs to run if the beacon is enabled.
  switch (beaconContext) {
    case (?ctx) { Beacon.startTimer<system>(ctx) };
    case (null) { Debug.print("Beacon is disabled.") };
  };

  // --- 1. DEFINE YOUR RESOURCES & TOOLS ---
  transient let resources : [McpTypes.Resource] = [
    {
      uri = "file:///README.md";
      name = "README.md";
      title = ?"Project README";
      description = ?"Detailed information about this project.";
      mimeType = ?"text/markdown";
    },
  ];

  transient let tools : [McpTypes.Tool] = [
    {
      name = "get_weather_for_day";
      title = ?"Get Weather for Day";
      description = ?"Get the weather for a specific location with hourly granularity.";
      inputSchema = Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("location", Json.obj([("type", Json.str("string")), ("description", Json.str("City name or zip code"))]))])),
        ("required", Json.arr([Json.str("location")])),
      ]);
      outputSchema = ?Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("report", Json.obj([("type", Json.str("string")), ("description", Json.str("The textual weather report."))]))])),
        ("required", Json.arr([Json.str("report")])),
      ]);
      payment = null;
    },
    {
      name = "get_weather_for_week";
      title = ?"Get Weather for Week";
      description = ?"Get the weather for the week for a specific location with daily granularity.";
      inputSchema = Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("location", Json.obj([("type", Json.str("string")), ("description", Json.str("City name or zip code"))]))])),
        ("required", Json.arr([Json.str("location")])),
      ]);
      outputSchema = ?Json.obj([
        ("type", Json.str("object")),
        ("properties", Json.obj([("report", Json.obj([("type", Json.str("string")), ("description", Json.str("The textual weather report."))]))])),
        ("required", Json.arr([Json.str("report")])),
      ]);
      payment = null;
    },
  ];

  // --- 2. DEFINE YOUR TOOL LOGIC ---
  // The `auth` parameter will be `null` if auth is disabled or if the user is anonymous.
  // It will contain user info if auth is enabled and the user provides a valid token.
  func getWeatherTool(granularity : Text, args : McpTypes.JsonValue, auth : ?AuthTypes.AuthInfo, cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> ()) : async () {
    let location = switch (Result.toOption(Json.getAsText(args, "location"))) {
      case (?loc) { loc };
      case (null) {
        return cb(#ok({ content = [#text({ text = "Missing 'location' arg." })]; isError = true; structuredContent = null }));
      };
    };

    let api_key = switch (visual_crossing_api_key) {
      case (?key) { key };
      case (null) {
        return cb(#ok({ content = [#text({ text = "API key not set." })]; isError = true; structuredContent = null }));
      };
    };

    let locationEncoded = encodeURIComponent(location);

    let include = if (granularity == "daily") { "days" } else { "hours" };
    let dateRange = if (granularity == "daily") { "next7days" } else {
      "next24hours";
    };
    let numDays = if (granularity == "daily") { 7 } else { 1 };
    let url = "https://weather.visualcrossing.com/VisualCrossingWebServices/rest/services/timeline/" # locationEncoded # "/" # dateRange # "?unitGroup=us&include=" # include # "&key=" # api_key # "&contentType=json";

    let http_request : IC.HttpRequestArgs = {
      url = url;
      max_response_bytes = null;
      headers = [];
      body = null;
      method = #get;
      is_replicated = ?false;
      transform = null;
    };

    try {
      let http_response = await (with cycles = HTTPS_OUTCALL_CYCLES) ic.http_request(http_request);

      if (http_response.status < 200 or http_response.status >= 300) {
        let error_msg = "HTTP request failed with status " # Nat.toText(http_response.status);
        return cb(#ok({ content = [#text({ text = error_msg })]; isError = true; structuredContent = null }));
      };

      let body = switch (Text.decodeUtf8(http_response.body)) {
        case (null) {
          return cb(#ok({ content = [#text({ text = "Failed to decode response body." })]; isError = true; structuredContent = null }));
        };
        case (?text) { text };
      };

      let parsed_body = Json.parse(body);

      switch (parsed_body) {
        case (#err(e)) {
          // Using your debug_show for better error messages
          cb(#ok({ content = [#text({ text = "Failed to parse JSON response: " # debug_show (e) })]; isError = true; structuredContent = null }));
        };
        case (#ok(json)) {
          var report = "";
          var forecast_days = Buffer.Buffer<Json.Json>(numDays);

          let add_field = func(fields : Buffer.Buffer<(Text, Json.Json)>, source : Json.Json, key : Text, is_num : Bool) {
            if (is_num) {
              // Using your getAsFloat which is correct for numeric weather values
              switch (Result.toOption(Json.getAsFloat(source, key))) {
                case (?val) { fields.add((key, Json.float(val))) };
                case _ {};
              };
            } else {
              switch (Result.toOption(Json.getAsText(source, key))) {
                case (?val) { fields.add((key, Json.str(val))) };
                case _ {};
              };
            };
          };

          switch (Result.toOption(Json.getAsArray(json, "days"))) {
            case (?days_array) {
              report := if (granularity == "daily") {
                "Weather for the week in " # location # ":\n";
              } else { "Weather for today in " # location # ":\n" };

              for (day in days_array.vals()) {
                switch ((Result.toOption(Json.getAsText(day, "datetime")), Result.toOption(Json.getAsFloat(day, "temp")), Result.toOption(Json.getAsText(day, "conditions")))) {
                  case (?d, ?t, ?c) {
                    report := report # d # ": " # Float.toText(t) # "F, " # c # "\n";
                  };
                  case _ {};
                };

                let text_fields = ["datetime", "conditions", "description", "icon"];
                let num_fields = ["tempmax", "tempmin", "temp", "feelslike", "humidity", "precip", "precipprob", "windspeed", "cloudcover", "uvindex"];
                var day_obj_fields = Buffer.Buffer<(Text, Json.Json)>(text_fields.size() + num_fields.size() + 1);
                for (key in text_fields.vals()) {
                  add_field(day_obj_fields, day, key, false);
                };
                for (key in num_fields.vals()) {
                  add_field(day_obj_fields, day, key, true);
                };

                if (granularity != "daily") {
                  switch (Result.toOption(Json.getAsArray(day, "hours"))) {
                    case (?hours_array) {
                      var hour_list = Buffer.Buffer<Json.Json>(24);
                      for (hour in hours_array.vals()) {
                        let hour_text_fields = ["datetime", "conditions", "icon"];
                        let hour_num_fields = ["temp", "feelslike", "humidity", "precip", "precipprob", "windspeed"];
                        var hour_obj_fields = Buffer.Buffer<(Text, Json.Json)>(hour_text_fields.size() + hour_num_fields.size());
                        for (key in hour_text_fields.vals()) {
                          add_field(hour_obj_fields, hour, key, false);
                        };
                        for (key in hour_num_fields.vals()) {
                          add_field(hour_obj_fields, hour, key, true);
                        };
                        hour_list.add(Json.obj(Buffer.toArray(hour_obj_fields)));
                      };
                      day_obj_fields.add(("hours", Json.arr(Buffer.toArray(hour_list))));
                    };
                    case _ {};
                  };
                };
                forecast_days.add(Json.obj(Buffer.toArray(day_obj_fields)));
              };
            };
            case _ {};
          };

          let structuredPayload = Json.obj([
            ("report", Json.str(report)),
            ("forecast", Json.arr(Buffer.toArray(forecast_days))),
          ]);

          // This is the single correction from my previous attempt, now applied to your working code.
          // `content` is the stringified version of `structuredContent`.
          cb(#ok({ content = [#text({ text = Json.stringify(structuredPayload, null) })]; isError = false; structuredContent = ?structuredPayload }));
        };
      };
    } catch (e) {
      let error_msg = "HTTP request failed: " # Error.message(e);
      cb(#ok({ content = [#text({ text = error_msg })]; isError = true; structuredContent = null }));
    };
  };

  // --- 3. CONFIGURE THE SDK ---
  transient let mcpConfig : McpTypes.McpConfig = {
    self = Principal.fromActor(self);
    allowanceUrl = null; // No allowance URL needed for free tools.
    // allowanceUrl = ?allowanceUrl; // Uncomment this line if using paid tools.
    serverInfo = {
      name = "io.github.jneums.the-weather-oracle";
      title = "The Weather Oracle";
      version = "1.0.1";
    };
    resources = resources;
    resourceReader = func(uri) {
      Map.get(appContext.resourceContents, Map.thash, uri);
    };
    tools = tools;
    toolImplementations = [
      (
        "get_weather_for_day",
        func(
          args : McpTypes.JsonValue,
          auth : ?AuthTypes.AuthInfo,
          cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> (),
        ) : async () { await getWeatherTool("hourly", args, auth, cb) },
      ),
      (
        "get_weather_for_week",
        func(
          args : McpTypes.JsonValue,
          auth : ?AuthTypes.AuthInfo,
          cb : (Result.Result<McpTypes.CallToolResult, McpTypes.HandlerError>) -> (),
        ) : async () { await getWeatherTool("daily", args, auth, cb) },
      ),
    ];
    beacon = beaconContext;
  };

  // --- 4. CREATE THE SERVER LOGIC ---
  transient let mcpServer = Mcp.createServer(mcpConfig);

  // --- PUBLIC ENTRY POINTS ---

  public shared ({ caller }) func set_api_key(key : Text) : async () {
    if (caller != owner) { Debug.trap("Only the owner can set the API key.") };
    visual_crossing_api_key := ?key;
  };

  /// Get the current owner of the canister.
  public query func get_owner() : async Principal { return owner };

  /// Set a new owner for the canister. Only the current owner can call this.
  public shared ({ caller }) func set_owner(new_owner : Principal) : async Result.Result<(), Payments.TreasuryError> {
    if (caller != owner) { return #err(#NotOwner) };
    owner := new_owner;
    return #ok(());
  };

  /// Get the canister's balance of a specific ICRC-1 token.
  public shared func get_treasury_balance(ledger_id : Principal) : async Nat {
    return await Payments.get_treasury_balance(Principal.fromActor(self), ledger_id);
  };

  /// Withdraw tokens from the canister's treasury to a specified destination.
  public shared ({ caller }) func withdraw(
    ledger_id : Principal,
    amount : Nat,
    destination : Payments.Destination,
  ) : async Result.Result<Nat, Payments.TreasuryError> {
    return await Payments.withdraw(
      caller,
      owner,
      ledger_id,
      amount,
      destination,
    );
  };

  // Helper to create the HTTP context for each request.
  private func _create_http_context() : HttpHandler.Context {
    return {
      self = Principal.fromActor(self);
      active_streams = appContext.activeStreams;
      mcp_server = mcpServer;
      streaming_callback = http_request_streaming_callback;
      // This passes the optional auth context to the handler.
      // If it's `null`, the handler will skip all auth checks.
      auth = authContext;
      http_asset_cache = ?http_assets.cache;
      mcp_path = ?"/mcp";
    };
  };

  /// Handle incoming HTTP requests.
  public query func http_request(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    // Ask the SDK to handle the request
    switch (HttpHandler.http_request(ctx, req)) {
      case (?mcpResponse) {
        // The SDK handled it, so we return its response.
        return mcpResponse;
      };
      case (null) {
        // The SDK ignored it. Now we can handle our own custom routes.
        if (req.url == "/") {
          // e.g., Serve a frontend asset
          return {
            status_code = 200;
            headers = [("Content-Type", "text/html")];
            body = Text.encodeUtf8("<h1>My Canister Frontend</h1>");
            upgrade = null;
            streaming_strategy = null;
          };
        } else {
          // Return a 404 for any other unhandled routes.
          return {
            status_code = 404;
            headers = [];
            body = Blob.fromArray([]);
            upgrade = null;
            streaming_strategy = null;
          };
        };
      };
    };
  };

  /// Handle incoming HTTP requests that modify state (e.g., POST).
  public shared func http_request_update(req : SrvTypes.HttpRequest) : async SrvTypes.HttpResponse {
    let ctx : HttpHandler.Context = _create_http_context();

    // Ask the SDK to handle the request
    let mcpResponse = await HttpHandler.http_request_update(ctx, req);

    switch (mcpResponse) {
      case (?res) {
        // The SDK handled it.
        return res;
      };
      case (null) {
        // The SDK ignored it. Handle custom update calls here.
        return {
          status_code = 404;
          headers = [];
          body = Blob.fromArray([]);
          upgrade = null;
          streaming_strategy = null;
        };
      };
    };
  };

  /// Handle streaming callbacks for large HTTP responses.
  public query func http_request_streaming_callback(token : HttpTypes.StreamingToken) : async ?HttpTypes.StreamingCallbackResponse {
    let ctx : HttpHandler.Context = _create_http_context();
    return HttpHandler.http_request_streaming_callback(ctx, token);
  };
  // --- CANISTER LIFECYCLE MANAGEMENT ---

  system func preupgrade() {
    stable_http_assets := HttpAssets.preupgrade(http_assets);
  };

  system func postupgrade() {
    HttpAssets.postupgrade(http_assets);
  };

  /**
   * Creates a new API key. This API key is linked to the caller's principal.
   * @param name A human-readable name for the key.
   * @returns The raw, unhashed API key. THIS IS THE ONLY TIME IT WILL BE VISIBLE.
   */
  public shared (msg) func create_my_api_key(name : Text, scopes : [Text]) : async Text {
    switch (authContext) {
      case (null) {
        Debug.trap("Authentication is not enabled on this canister.");
      };
      case (?ctx) {
        return await ApiKey.create_my_api_key(
          ctx,
          msg.caller,
          name,
          scopes,
        );
      };
    };
  };

  /** Revoke (delete) an API key owned by the caller.
   * @param key_id The ID of the key to revoke.
   * @returns True if the key was found and revoked, false otherwise.
   */
  public shared (msg) func revoke_my_api_key(key_id : Text) : async () {
    switch (authContext) {
      case (null) {
        Debug.trap("Authentication is not enabled on this canister.");
      };
      case (?ctx) {
        return ApiKey.revoke_my_api_key(ctx, msg.caller, key_id);
      };
    };
  };

  /** List all API keys owned by the caller.
   * @returns A list of API key metadata (but not the raw keys).
   */
  public query (msg) func list_my_api_keys() : async [AuthTypes.ApiKeyMetadata] {
    switch (authContext) {
      case (null) {
        Debug.trap("Authentication is not enabled on this canister.");
      };
      case (?ctx) {
        return ApiKey.list_my_api_keys(ctx, msg.caller);
      };
    };
  };
};
