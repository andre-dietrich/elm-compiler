// Pluggable transport for Crdt.Sync's two ports (crdtSend/crdtReceive).
// Default: BroadcastChannel (same-browser tabs/windows, same origin, no
// server). Swap in a different provider by passing { provider } to
// attachCrdtSync -- anything with the same { send(value), onMessage(cb) }
// shape works (e.g. a WebSocket-backed provider for cross-device sync).

function makeBroadcastChannelProvider(channelName) {
  var channel = new BroadcastChannel(channelName);
  var listeners = [];
  channel.onmessage = function (event) {
    listeners.forEach(function (cb) {
      cb(event.data);
    });
  };
  return {
    send: function (value) {
      channel.postMessage(value);
    },
    onMessage: function (cb) {
      listeners.push(cb);
    },
  };
}

// Exact UTF-8 byte size (String.length in JS counts UTF-16 code units,
// which undercounts anything outside the ASCII range).
function byteSize(json) {
  return new TextEncoder().encode(json).length;
}

function logMessage(direction, value) {
  var json = JSON.stringify(value);
  var bytes = byteSize(json);
  var kb = (bytes / 1024).toFixed(2);
  console.log("[crdt " + direction + "] " + bytes + " B (" + kb + " KB)", value);
}

// Every open tab answers a "requestState" with its full (potentially large,
// e.g. 1MB+ once a shared doc has grown) state -- with several tabs open,
// a newly opened/reloaded tab used to get hit with N simultaneous full-state
// blobs, each JSON-decoded synchronously on the main thread, which is what
// made things freeze. Mitigation: don't forward "requestState" into Elm
// immediately -- wait a random backoff first, and drop it if a "fullState"
// reply (from a peer whose backoff fired first) shows up before then. This
// doesn't change CRDT correctness (the requester still gets a reply from
// whichever peer wins the race) or `Crdt.Sync`'s wire format -- it only
// changes *when*, and how many times, Elm ends up building a reply.
var BACKOFF_MAX_MS = 300;

function attachCrdtSync(app, options) {
  var provider = (options && options.provider) || makeBroadcastChannelProvider("browser-app-tabs-demo");
  var pendingRequestTimer = null;

  app.ports.crdtSend.subscribe(function (value) {
    logMessage("send", value);
    provider.send(value);
  });

  provider.onMessage(function (value) {
    logMessage("recv", value);

    if (value && value.kind === "requestState") {
      var delay = Math.floor(Math.random() * BACKOFF_MAX_MS);
      pendingRequestTimer = setTimeout(function () {
        pendingRequestTimer = null;
        app.ports.crdtReceive.send(value);
      }, delay);
      return;
    }

    if (value && value.kind === "fullState" && pendingRequestTimer !== null) {
      clearTimeout(pendingRequestTimer);
      pendingRequestTimer = null;
    }

    app.ports.crdtReceive.send(value);
  });
}
