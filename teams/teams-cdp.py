#!/usr/bin/env python3
"""One-shot Chrome DevTools Protocol client for the Microsoft Teams microphone mute state.

Usage: teams-cdp.py status|toggle|mute|unmute|discover
Port: TEAMS_DEBUG_PORT (default 9333), always on 127.0.0.1.
Exit codes: 0 ok, 1 error, 3 debug port not reachable, 4 not in a call.

Standard library only. Only the mic button's mute attribute is ever read; no page content, tokens or
target details are printed or stored.
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
# Selectors and state mapping. Taken from the verified cliui research (theboxstuff/cliui/daemon/docs/teams-debug-port-approach.md):
# the in-call mic button matches [aria-label*=mic i]; its label names the NEXT action, so
# "Unmute mic" means currently muted and "Mute mic" means currently unmuted. Verified there on Teams 26213; not yet on this build.
# Fix these from `teams-mute discover` output; nothing else in the file should need to change.
# ---------------------------------------------------------------------------------------------
# #SUGGEST_VERIFY: join a test call, run `teams-mute status` muted and unmuted, compare with the real mic state
MIC_BUTTON_SELECTORS = ['[aria-label*="mic" i]']
MUTED_LABEL_PATTERN = "^unmute"
UNMUTED_LABEL_PATTERN = "^mute"
# #COMPLETION_DRIVE: call pages are served from these hosts (cliui research filtered on teams.microsoft.com)
# #SUGGEST_VERIFY: if status always reports no-call during a call, widen this list after checking the host of the call window
TEAMS_HOST_SUFFIXES = ("teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com")
DISCOVER_NAME_PATTERN = "mic|mute"

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
STATE_MUTED = "muted"
STATE_UNMUTED = "unmuted"
STATE_UNKNOWN = "unknown"
VALID_PAGE_STATES = (STATE_NO_CALL, STATE_MUTED, STATE_UNMUTED, STATE_UNKNOWN)

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
FIND_BUTTON_SCRIPT = """
  var selectors = %(selectors)s;
  var button = null;
  for (var index = 0; index < selectors.length && !button; index++) {
    button = document.querySelector(selectors[index]);
  }
""" % {"selectors": json.dumps(MIC_BUTTON_SELECTORS)}

STATE_EXPRESSION = "/*teams-cdp:state*/(function () {" + FIND_BUTTON_SCRIPT + """
  if (!button) return "no-call";
  var label = (button.getAttribute("aria-label") || "").trim();
  if (new RegExp(%(mutedPattern)s, "i").test(label)) return "muted";
  if (new RegExp(%(unmutedPattern)s, "i").test(label)) return "unmuted";
  return "unknown";
})()""" % {"mutedPattern": json.dumps(MUTED_LABEL_PATTERN), "unmutedPattern": json.dumps(UNMUTED_LABEL_PATTERN)}

CLICK_EXPRESSION = "/*teams-cdp:click*/(function () {" + FIND_BUTTON_SCRIPT + """
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


def list_candidate_target_identifiers(port, deadline):
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
    return [target["id"] for target in targets if is_candidate_target(target)]


def read_state(session):
    state = session.evaluate(STATE_EXPRESSION)
    if state not in VALID_PAGE_STATES:
        raise CdpError("unexpected state value from page")
    return state


def open_call_session(port, deadline):
    """Returns (session, state) for the first target that has the mic button, or (None, STATE_NO_CALL)."""
    for targetIdentifier in list_candidate_target_identifiers(port, deadline):
        session = CdpSession(port, targetIdentifier, deadline)
        try:
            state = read_state(session)
        except BaseException:
            session.close()
            raise
        if state != STATE_NO_CALL:
            return session, state
        session.close()
    return None, STATE_NO_CALL


def click_and_read_state(session):
    if session.evaluate(CLICK_EXPRESSION) != "clicked":
        raise CdpError("mic button disappeared before the click")
    time.sleep(POST_CLICK_SETTLE_SECONDS)
    return read_state(session)


def change_mute_state(session, currentState, desiredState):
    if currentState == desiredState:
        return currentState
    newState = click_and_read_state(session)
    if newState != desiredState:
        raise CdpError("clicked the mic button but state is %s, expected %s" % (newState, desiredState))
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
        raise CdpError("no mic/mute button candidates found; join a call first", EXIT_NOT_IN_CALL)
    print("\n".join(lines))
    return EXIT_OK


def run_state_command(command, port, deadline):
    session, state = open_call_session(port, deadline)
    if session is None:
        if command == "status":
            print(STATE_NO_CALL)
        raise CdpError("not in a call (no mic button found)", EXIT_NOT_IN_CALL)
    try:
        if state == STATE_UNKNOWN:
            raise CdpError("mic button found but its aria-label is neither mute nor unmute; run discover")
        if command == "toggle":
            desiredState = STATE_UNMUTED if state == STATE_MUTED else STATE_MUTED
        else:
            desiredState = {"status": state, "mute": STATE_MUTED, "unmute": STATE_UNMUTED}[command]
        print(change_mute_state(session, state, desiredState))
    finally:
        session.close()
    return EXIT_OK


def main(arguments):
    commands = ("status", "toggle", "mute", "unmute", "discover")
    if len(arguments) != 1 or arguments[0] not in commands:
        print("usage: teams-cdp.py status|toggle|mute|unmute|discover", file=sys.stderr)
        return EXIT_ERROR
    try:
        port = read_debug_port()
        deadline = Deadline(COMMAND_DEADLINE_SECONDS)
        if arguments[0] == "discover":
            return run_discover(port, deadline)
        return run_state_command(arguments[0], port, deadline)
    except CdpError as error:
        print("teams-cdp: %s" % error, file=sys.stderr)
        return error.exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
