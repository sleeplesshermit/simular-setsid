#!/bin/sh
# Direct shell entry (platforms/eggs that run a start script instead of node).
exec sh "$(dirname "$0")/pico.sh"
