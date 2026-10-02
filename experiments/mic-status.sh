#!/bin/bash
# EXPERIMENT. Title for an MTMR shellScriptTitledButton showing the Teams mic state.
#   muted   -> white on red     "MUTED"
#   unmuted -> black on green   "MIC"
#   desync  -> black on yellow  "MIC?"   (Teams running but its state cannot be read)
#   no call -> prints nothing: MTMR hides a script button whose output is empty.
# MTMR takes the button's background colour from the ANSI background of the first character (16 colours only).
teamsMute="${TEAMS_MUTE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../teams" && pwd)/teams-mute}"

teamsState="$("${teamsMute}" status 2>/dev/null)"
statusExitCode=$?

case "${statusExitCode}:${teamsState}" in
  0:muted) printf '\033[97;41m MUTED \033[0m' ;;
  0:unmuted) printf '\033[30;42m  MIC  \033[0m' ;;
  4:*) ;;
  3:*) if pgrep -x MSTeams >/dev/null; then printf '\033[30;43m MIC? \033[0m'; fi ;;
  *) printf '\033[30;43m MIC? \033[0m' ;;
esac
