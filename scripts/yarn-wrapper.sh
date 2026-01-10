#!/bin/sh
# Wrapper script to handle "yarn config get registry" for Next.js SWC download
# This is needed because Yarn 4 doesn't support "yarn config get registry" without the npm-cli plugin

if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  # Return npm registry URL (default is https://registry.npmjs.org/)
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi

# For all other commands, pass through to the real yarn
exec /usr/local/bin/yarn "$@"
