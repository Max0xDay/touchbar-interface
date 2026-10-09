#!/usr/bin/env python3
"""One-shot Chrome DevTools Protocol client for the Microsoft Teams microphone mute state.

Usage: teams-cdp.py status|toggle|mute|unmute|discover|meeting
Port: TEAMS_DEBUG_PORT (default 9333), always on 127.0.0.1.
Exit codes: 0 ok, 1 error, 3 debug port not reachable, 4 not in a call.

Standard library only. Only the mic button's mute attribute is ever read from a page; no page content or
tokens are printed or stored. `meeting` prints the window title of the call page (target metadata from the
debug port's /json list, e.g. "Weekly sync | Microsoft Teams" -> "Weekly sync").
"""
import base64
import hashlib
import http.client
import json
import os
import re
import socket
import struct
import sys
import time
from urllib.parse import urlparse

# ---------------------------------------------------------------------------------------------
# Selectors and state mapping. Taken from earlier private research notes:
# the in-call mic button matches [aria-label*=mic i]; its label names the NEXT action, so
# "Unmute mic" means currently muted and "Mute mic" means currently unmuted. Verified there on Teams 26213; not yet on this build.
# Fix these from `teams-mute discover` output; nothing else in the file should need to change.
# ---------------------------------------------------------------------------------------------
# #SUGGEST_VERIFY: join a test call, run `teams-mute status` muted and unmuted, compare with the real mic state
# Each device: the button selector, the label a real button must start with ("mic" alone also matches
# "Microsoft ..." in the main window outside calls, Verified 2026-10-07), and label pattern -> state.
# Camera labels name the next action too: "Turn camera on" = camera off (Verified 2026-10-07).
DEVICES = {
    "mic": {
        "selector": '[aria-label*="mic" i]',
        "label": "^(un)?mute",
        "states": [["^unmute", "muted"], ["^mute", "unmuted"]],
    },
    "camera": {
        "selector": '[aria-label*="camera" i]',
        "label": "^turn camera (on|off)",
        "states": [["^turn camera on", "off"], ["^turn camera off", "on"]],
    },
}
# #COMPLETION_DRIVE: call pages are served from these hosts (earlier research filtered on teams.microsoft.com)
# #SUGGEST_VERIFY: if status always reports no-call during a call, widen this list after checking the host of the call window
TEAMS_HOST_SUFFIXES = ("teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com")
DISCOVER_NAME_PATTERN = "mic|mute|camera|video"

DEFAULT_DEBUG_PORT = 9333
LOOPBACK_ADDRESS = "127.0.0.1"
COMMAND_DEADLINE_SECONDS = 3.0
SOCKET_OPERATION_TIMEOUT_SECONDS = 1.0
POST_CLICK_SETTLE_SECONDS = 0.3
MAXIMUM_HTTP_BODY_BYTES = 1024 * 1024
MAXIMUM_WEBSOCKET_MESSAGE_BYTES = 1024 * 1024
MAXIMUM_DISCOVER_CANDIDATES = 20
MAXIMUM_LABEL_LENGTH = 80
TARGET_IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9-]+$")
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_PORT_UNREACHABLE = 3
EXIT_NOT_IN_CALL = 4

STATE_NO_CALL = "no-call"
STATE_UNKNOWN = "unknown"
# Command -> (device, desired state); None = keep the current state (status), "toggle" = the other state.
COMMANDS = {
    "status": ("mic", None), "toggle": ("mic", "toggle"), "mute": ("mic", "muted"), "unmute": ("mic", "unmuted"),
    "camera-status": ("camera", None), "camera-toggle": ("camera", "toggle"), "camera-on": ("camera", "on"), "camera-off": ("camera", "off"),
}

OPCODE_CONTINUATION = 0x0
OPCODE_TEXT = 0x1
OPCODE_BINARY = 0x2
OPCODE_CLOSE = 0x8
OPCODE_PING = 0x9
OPCODE_PONG = 0xA


class CdpError(Exception):
    def __init__(self, message, exit_code=EXIT_ERROR):
        super().__init__(message)
        self.exit_code = exit_code


class Deadline:
    def __init__(self, totalSeconds):
        self.endMonotonicSeconds = time.monotonic() + totalSeconds

    def next_socket_timeout_seconds(self):
        remainingSeconds = self.endMonotonicSeconds - time.monotonic()
        if remainingSeconds <= 0:
            raise CdpError("timed out")
        return min(remainingSeconds, SOCKET_OPERATION_TIMEOUT_SECONDS)


class WebSocketConnection:
    """Minimal RFC 6455 client: handshake, masked text frames, ping/pong, close, fragmented messages."""

    def __init__(self, port, path, deadline):
        self.deadline = deadline
        self.socket = self._open_socket(port)
        try:
            self._handshake(port, path)
        except BaseException:
            self.socket.close()
            raise

    def _open_socket(self, port):
        try:
            return socket.create_connection((LOOPBACK_ADDRESS, port), self.deadline.next_socket_timeout_seconds())
        except OSError as error:
            raise CdpError("websocket connect failed: %s" % error.__class__.__name__, EXIT_PORT_UNREACHABLE)

    def _handshake(self, port, path):
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ) % (path, LOOPBACK_ADDRESS, port, key)
        self._send_all(request.encode("ascii"))
        responseHeaderText = self._read_http_header()
        headerLines = responseHeaderText.split("\r\n")
        if len(headerLines[0].split(" ")) < 2 or headerLines[0].split(" ")[1] != "101":
            raise CdpError("websocket upgrade refused: %s" % headerLines[0][:40])
        headers = {}
        for line in headerLines[1:]:
            name, separator, value = line.partition(":")
            if separator:
                headers[name.strip().lower()] = value.strip()
        expectedAccept = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii")).digest()).decode("ascii")
        if headers.get("sec-websocket-accept") != expectedAccept:
            raise CdpError("websocket handshake accept key mismatch")

    def _read_http_header(self):
        received = b""
        while b"\r\n\r\n" not in received:
            if len(received) > 16 * 1024:
                raise CdpError("websocket handshake header too large")
            # Reads one byte at a time so no frame bytes after the header are consumed.
            received += self._read_exact(1)
        return received.decode("latin-1").split("\r\n\r\n")[0]

    def _send_all(self, data):
        self.socket.settimeout(self.deadline.next_socket_timeout_seconds())
        try:
            self.socket.sendall(data)
        except (socket.timeout, OSError) as error:
            raise CdpError("websocket send failed: %s" % error.__class__.__name__)

    def _read_exact(self, byteCount):
        chunks = []
        remaining = byteCount
        while remaining > 0:
            self.socket.settimeout(self.deadline.next_socket_timeout_seconds())
            try:
                chunk = self.socket.recv(remaining)
            except (socket.timeout, OSError) as error:
                raise CdpError("websocket read failed: %s" % error.__class__.__name__)
            if not chunk:
                raise CdpError("websocket closed by peer")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _send_frame(self, opcode, payload):
        maskKey = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        maskedPayload = bytes(byte ^ maskKey[index % 4] for index, byte in enumerate(payload))
        self._send_all(header + maskKey + maskedPayload)

    def send_text(self, text):
        self._send_frame(OPCODE_TEXT, text.encode("utf-8"))

    def _read_frame(self):
        firstByte, secondByte = self._read_exact(2)
        isFinal = bool(firstByte & 0x80)
        opcode = firstByte & 0x0F
        if secondByte & 0x80:
            raise CdpError("websocket server frame was masked")
        length = secondByte & 0x7F
        if length == 126:
            length = struct.unpack(">H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self._read_exact(8))[0]
        if length > MAXIMUM_WEBSOCKET_MESSAGE_BYTES:
            raise CdpError("websocket frame too large")
        return isFinal, opcode, self._read_exact(length)

    def receive_text(self):
        messageParts = []
        messageBytes = 0
        while True:
            isFinal, opcode, payload = self._read_frame()
            if opcode == OPCODE_PING:
                self._send_frame(OPCODE_PONG, payload)
                continue
            if opcode == OPCODE_PONG:
                continue
            if opcode == OPCODE_CLOSE:
                raise CdpError("websocket closed by peer")
            if opcode not in (OPCODE_TEXT, OPCODE_BINARY, OPCODE_CONTINUATION):
                raise CdpError("websocket unsupported opcode %d" % opcode)
            messageBytes += len(payload)
            if messageBytes > MAXIMUM_WEBSOCKET_MESSAGE_BYTES:
                raise CdpError("websocket message too large")
            messageParts.append(payload)
            if isFinal:
                return b"".join(messageParts).decode("utf-8")

    def close(self):
        self.socket.close()


class CdpSession:
    def __init__(self, port, targetIdentifier, deadline):
        self.connection = WebSocketConnection(port, "/devtools/page/" + targetIdentifier, deadline)
        self.nextRequestIdentifier = 1

    def evaluate(self, expression):
        requestIdentifier = self.nextRequestIdentifier
        self.nextRequestIdentifier += 1
        self.connection.send_text(json.dumps({
            "id": requestIdentifier,
            "method": "Runtime.evaluate",
            "params": {"expression": expression, "returnByValue": True},
        }))
        while True:
            try:
                message = json.loads(self.connection.receive_text())
            except ValueError:
                raise CdpError("CDP sent a non-JSON message")
            if message.get("id") != requestIdentifier:
                continue
            return self._extract_value(message)

    @staticmethod
    def _extract_value(message):
        if "error" in message:
            raise CdpError("CDP error code %s" % message["error"].get("code"))
        result = message.get("result", {})
        if "exceptionDetails" in result:
            raise CdpError("page script threw an exception")
        return result.get("result", {}).get("value")

    def close(self):
        self.connection.close()


# ---------------------------------------------------------------------------------------------
# Page scripts. Tagged comments let the local fake server tell them apart.
# ---------------------------------------------------------------------------------------------
def find_button_script(device):
    return """
  var button = null;
  var label = new RegExp(%(label)s, "i");
  var nodes = document.querySelectorAll(%(selector)s);
  for (var n = 0; n < nodes.length && !button; n++) {
    if (label.test((nodes[n].getAttribute("aria-label") || "").trim())) button = nodes[n];
  }
""" % {"selector": json.dumps(DEVICES[device]["selector"]), "label": json.dumps(DEVICES[device]["label"])}


def state_expression(device):
    return "/*teams-cdp:state*/(function () {" + find_button_script(device) + """
  if (!button) return "no-call";
  var text = (button.getAttribute("aria-label") || "").trim();
  var states = %(states)s;
  for (var s = 0; s < states.length; s++) {
    if (new RegExp(states[s][0], "i").test(text)) return states[s][1];
  }
  return "unknown";
})()""" % {"states": json.dumps(DEVICES[device]["states"])}


def click_expression(device):
    return "/*teams-cdp:click*/(function () {" + find_button_script(device) + """
  if (!button) return "no-call";
  button.click();
  return "clicked";
})()"""


DISCOVER_EXPRESSION = """/*teams-cdp:discover*/(function () {
  var pattern = new RegExp(%(pattern)s, "i");
  var nodes = document.querySelectorAll("button, [role=button], [role=switch]");
  var candidates = [];
  for (var index = 0; index < nodes.length && candidates.length < %(limit)d; index++) {
    var node = nodes[index];
    var dataTid = node.getAttribute("data-tid");
    var ariaLabel = node.getAttribute("aria-label");
    if (pattern.test((dataTid || "") + " " + (ariaLabel || ""))) {
      candidates.push({
        tag: node.tagName.toLowerCase(),
        dataTid: dataTid,
        ariaLabel: ariaLabel === null ? null : ariaLabel.slice(0, %(labelLength)d),
        ariaPressed: node.getAttribute("aria-pressed")
      });
    }
  }
  return JSON.stringify(candidates);
})()""" % {
    "pattern": json.dumps(DISCOVER_NAME_PATTERN),
    "limit": MAXIMUM_DISCOVER_CANDIDATES,
    "labelLength": MAXIMUM_LABEL_LENGTH,
}


def read_debug_port():
    rawPort = os.environ.get("TEAMS_DEBUG_PORT", str(DEFAULT_DEBUG_PORT))
    if not rawPort.isdigit() or not 1024 <= int(rawPort) <= 65535:
        raise CdpError("TEAMS_DEBUG_PORT must be a number from 1024 to 65535, got %r" % rawPort)
    return int(rawPort)


def is_teams_host(hostname):
    return any(hostname == suffix or hostname.endswith("." + suffix) for suffix in TEAMS_HOST_SUFFIXES)


def is_candidate_target(target):
    if not isinstance(target, dict) or target.get("type") != "page":
        return False
    identifier = target.get("id")
    if not isinstance(identifier, str) or not TARGET_IDENTIFIER_PATTERN.match(identifier):
        return False
    return is_teams_host(urlparse(str(target.get("url", ""))).hostname or "")


def list_candidate_targets(port, deadline):
    connection = http.client.HTTPConnection(LOOPBACK_ADDRESS, port, timeout=deadline.next_socket_timeout_seconds())
    try:
        connection.request("GET", "/json")
        response = connection.getresponse()
        body = response.read(MAXIMUM_HTTP_BODY_BYTES)
        statusCode = response.status
    except (OSError, http.client.HTTPException) as error:
        raise CdpError("debug port %d not reachable (%s)" % (port, error.__class__.__name__), EXIT_PORT_UNREACHABLE)
    finally:
        connection.close()
    if statusCode != 200:
        raise CdpError("debug port answered HTTP %d" % statusCode)
    try:
        targets = json.loads(body)
    except ValueError:
        raise CdpError("debug port sent a non-JSON target list")
    if not isinstance(targets, list):
        raise CdpError("debug port sent an unexpected target list")
    return [target for target in targets if is_candidate_target(target)]


def list_candidate_target_identifiers(port, deadline):
    return [target["id"] for target in list_candidate_targets(port, deadline)]


TEAMS_TITLE_SUFFIX = " | Microsoft Teams"


def meeting_title(target):
    title = str(target.get("title", "")).strip()
    if title.endswith(TEAMS_TITLE_SUFFIX):
        title = title[:-len(TEAMS_TITLE_SUFFIX)].strip()
    return title[:MAXIMUM_LABEL_LENGTH] if title and title != "Microsoft Teams" else ""


def run_meeting(port, deadline):
    """Prints the title of the call window (the page that has the mic button); exit 4 when not in a call."""
    for target in list_candidate_targets(port, deadline):
        session = CdpSession(port, target["id"], deadline)
        try:
            state = read_state(session, "mic")
        finally:
            session.close()
        if state != STATE_NO_CALL:
            print(meeting_title(target))
            return EXIT_OK
    raise CdpError("not in a call (no mic button found)", EXIT_NOT_IN_CALL)


def read_state(session, device):
    state = session.evaluate(state_expression(device))
    if state not in [STATE_NO_CALL, STATE_UNKNOWN] + [name for _, name in DEVICES[device]["states"]]:
        raise CdpError("unexpected state value from page")
    return state


def open_call_session(port, deadline, device):
    """Returns (session, state) for the first target that has the device's button, or (None, STATE_NO_CALL)."""
    for targetIdentifier in list_candidate_target_identifiers(port, deadline):
        session = CdpSession(port, targetIdentifier, deadline)
        try:
            state = read_state(session, device)
        except BaseException:
            session.close()
            raise
        if state != STATE_NO_CALL:
            return session, state
        session.close()
    return None, STATE_NO_CALL


def click_and_read_state(session, device):
    if session.evaluate(click_expression(device)) != "clicked":
        raise CdpError("%s button disappeared before the click" % device)
    time.sleep(POST_CLICK_SETTLE_SECONDS)
    return read_state(session, device)


def change_state(session, device, currentState, desiredState):
    if currentState == desiredState:
        return currentState
    newState = click_and_read_state(session, device)
    if newState != desiredState:
        raise CdpError("clicked the %s button but state is %s, expected %s" % (device, newState, desiredState))
    return newState


def format_discover_line(candidate):
    def cell(name, value):
        return "%s=%s" % (name, "-" if value is None else json.dumps(str(value)[:MAXIMUM_LABEL_LENGTH]))
    return "\t".join([
        str(candidate.get("tag", "-"))[:20],
        cell("data-tid", candidate.get("dataTid")),
        cell("aria-label", candidate.get("ariaLabel")),
        cell("aria-pressed", candidate.get("ariaPressed")),
    ])


def collect_discover_lines(port, deadline):
    lines = []
    for targetIdentifier in list_candidate_target_identifiers(port, deadline):
        session = CdpSession(port, targetIdentifier, deadline)
        try:
            rawCandidates = session.evaluate(DISCOVER_EXPRESSION)
        finally:
            session.close()
        if not isinstance(rawCandidates, str):
            raise CdpError("unexpected discover value from page")
        try:
            candidates = json.loads(rawCandidates)
        except ValueError:
            raise CdpError("discover result was not JSON")
        lines.extend(format_discover_line(candidate) for candidate in candidates if isinstance(candidate, dict))
    return lines


def run_discover(port, deadline):
    lines = collect_discover_lines(port, deadline)
    if not lines:
        raise CdpError("no mic/camera button candidates found; join a call first", EXIT_NOT_IN_CALL)
    print("\n".join(lines))
    return EXIT_OK


def run_state_command(command, port, deadline):
    device, desired = COMMANDS[command]
    session, state = open_call_session(port, deadline, device)
    if session is None:
        if desired is None:
            print(STATE_NO_CALL)
        raise CdpError("not in a call (no %s button found)" % device, EXIT_NOT_IN_CALL)
    try:
        if state == STATE_UNKNOWN:
            raise CdpError("%s button found but its aria-label matches no known state; run discover" % device)
        names = [name for _, name in DEVICES[device]["states"]]
        if desired == "toggle":
            desired = names[1] if state == names[0] else names[0]
        print(change_state(session, device, state, desired or state))
    finally:
        session.close()
    return EXIT_OK


def main(arguments):
    commands = tuple(COMMANDS) + ("discover", "meeting")
    if len(arguments) != 1 or arguments[0] not in commands:
        print("usage: teams-cdp.py %s" % "|".join(commands), file=sys.stderr)
        return EXIT_ERROR
    try:
        port = read_debug_port()
        deadline = Deadline(COMMAND_DEADLINE_SECONDS)
        if arguments[0] == "discover":
            return run_discover(port, deadline)
        if arguments[0] == "meeting":
            return run_meeting(port, deadline)
        return run_state_command(arguments[0], port, deadline)
    except CdpError as error:
        print("teams-cdp: %s" % error, file=sys.stderr)
        return error.exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
