// Pluggable transport for Crdt.Sync's two ports (crdtSend/crdtReceive).
// Default: BroadcastChannel (same-browser tabs/windows, same origin, no
// server). Swap in a different provider by passing { provider } to
// attachCrdtSync -- anything with the same { send(value), onMessage(cb) }
// shape works (e.g. a WebSocket-backed provider for cross-device sync).
//
// The port now carries a "binary string": one JS UTF-16 code unit per
// wire byte (value 0-255), produced/consumed by Crdt.Wire.toPortString/
// fromPortString on the Elm side, for BOTH codecs (Shared.Json wraps its
// JSON text as bytes too -- see Shared/Json.elm). Every WireMsg -- under
// either codec -- starts with one tag byte (0=op, 1=requestState,
// 2=fullState); that convention is what lets this file detect message
// kind for the backoff/suppression logic below without decoding the rest
// of the payload, since the port no longer carries a structured JS object
// the way `Json.Encode.Value` used to.

var KIND_OP = 0;
var KIND_REQUEST_STATE = 1;
var KIND_FULL_STATE = 2;

function makeBroadcastChannelProvider(channelName) {
  var channel = new BroadcastChannel(channelName);
  var listeners = [];
  channel.onmessage = function (event) {
    listeners.forEach(function (cb) {
      cb(event.data);
    });
  };
  return {
    send: function (bytes) {
      channel.postMessage(bytes);
    },
    onMessage: function (cb) {
      listeners.push(cb);
    },
  };
}

function portStringToBytes(portString) {
  return Uint8Array.from(portString, function (c) {
    return c.charCodeAt(0);
  });
}

// Chunked to avoid the spread-argument stack limit on large buffers.
function bytesToPortString(bytes) {
  var s = "";
  for (var i = 0; i < bytes.length; i += 8192) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
  }
  return s;
}

function messageKind(bytes) {
  return bytes.length > 0 ? bytes[0] : -1;
}

// Best-effort human-readable preview for the console log. Only meaningful
// for the JSON codec's framing (tag byte + varint length prefix + UTF-8
// JSON text, see Shared/Json.elm's encodeWireMsg) -- returns null for
// anything else (RequestState has no payload, and the binary codec's
// payload isn't JSON at all).
function tryPreviewJson(bytes) {
  if (bytes.length < 1 || (bytes[0] !== KIND_OP && bytes[0] !== KIND_FULL_STATE)) {
    return null;
  }
  var offset = 1;
  var shift = 0;
  var length = 0;
  while (offset < bytes.length) {
    var byte = bytes[offset];
    length |= (byte & 0x7f) << shift;
    offset += 1;
    shift += 7;
    if ((byte & 0x80) === 0) break;
  }
  var textBytes = bytes.subarray(offset, offset + length);
  try {
    return JSON.parse(new TextDecoder().decode(textBytes));
  } catch (e) {
    return null;
  }
}

function logMessage(direction, bytes) {
  var kb = (bytes.length / 1024).toFixed(2);
  var preview = tryPreviewJson(bytes);
  if (preview !== null) {
    console.log("[crdt " + direction + "] " + bytes.length + " B (" + kb + " KB)", preview);
  } else {
    var hex = Array.prototype.slice
      .call(bytes.subarray(0, 32))
      .map(function (b) {
        return b.toString(16).padStart(2, "0");
      })
      .join(" ");
    console.log(
      "[crdt " + direction + "] " + bytes.length + " B (" + kb + " KB) " + hex + (bytes.length > 32 ? "..." : "")
    );
  }
}

// Every open tab answers a "requestState" with its full (potentially large,
// e.g. 1MB+ once a shared doc has grown) state -- with several tabs open,
// a newly opened/reloaded tab used to get hit with N simultaneous full-state
// blobs, each decoded synchronously on the main thread, which is what made
// things freeze. Mitigation: don't forward "requestState" into Elm
// immediately -- wait a random backoff first, and drop it if a "fullState"
// reply (from a peer whose backoff fired first) shows up before then. This
// doesn't change CRDT correctness (the requester still gets a reply from
// whichever peer wins the race) or `Crdt.Sync`'s wire format -- it only
// changes *when*, and how many times, Elm ends up building a reply.
var BACKOFF_MAX_MS = 300;

function attachCrdtSync(app, options) {
  var provider = (options && options.provider) || makeBroadcastChannelProvider("browser-app-tabs-demo");
  var pendingRequestTimer = null;

  app.ports.crdtSend.subscribe(function (portString) {
    var bytes = portStringToBytes(portString);
    logMessage("send", bytes);
    provider.send(bytes);
  });

  provider.onMessage(function (bytes) {
    logMessage("recv", bytes);
    var kind = messageKind(bytes);

    if (kind === KIND_REQUEST_STATE) {
      var delay = Math.floor(Math.random() * BACKOFF_MAX_MS);
      pendingRequestTimer = setTimeout(function () {
        pendingRequestTimer = null;
        app.ports.crdtReceive.send(bytesToPortString(bytes));
      }, delay);
      return;
    }

    if (kind === KIND_FULL_STATE && pendingRequestTimer !== null) {
      clearTimeout(pendingRequestTimer);
      pendingRequestTimer = null;
    }

    app.ports.crdtReceive.send(bytesToPortString(bytes));
  });
}
