#!/bin/sh
# =============================================================================
# sudo -A helper for the desktop app
# =============================================================================
# A terminal lets sudo ask for a password directly. The app has no terminal, so
# it runs the installer with `sudo -A` and points SUDO_ASKPASS here: the app
# takes the password in its own dialog, writes it to a 0600 temporary file, and
# names that file in RRO_SUDO_PASSWORD_FILE. The file is deleted when the run
# ends, and the password is never written into the clone or into a log.
#
# Reading the file (rather than consuming it) is deliberate: one install is
# several sudo calls, and sudo may ask again within the same run.
[ -n "${RRO_SUDO_PASSWORD_FILE:-}" ] || exit 1
[ -r "${RRO_SUDO_PASSWORD_FILE}" ] || exit 1
exec cat "${RRO_SUDO_PASSWORD_FILE}"
