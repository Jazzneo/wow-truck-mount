#!/usr/bin/env bash
# Truck Mount - remove the truck patch from WoW (Linux / Steam Deck)
exec bash "$(dirname "${BASH_SOURCE[0]}")/install-client.sh" --uninstall "$@"
