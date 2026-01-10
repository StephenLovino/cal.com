#!/bin/sh
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

# Set up yarn wrapper to handle "yarn config get registry" for Next.js SWC download
# This fixes the issue where Yarn 4 doesn't support this command without npm-cli plugin
# Find all possible yarn locations and wrap them
for YARN_PATH in /usr/local/bin/yarn /usr/bin/yarn $(command -v yarn 2>/dev/null); do
  if [ -f "$YARN_PATH" ] && [ ! -f "${YARN_PATH}.real" ]; then
    mv "$YARN_PATH" "${YARN_PATH}.real"
    # Create wrapper script that intercepts "yarn config get registry"
    cat > "$YARN_PATH" << 'WRAPPER_EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi
exec "$0.real" "$@"
WRAPPER_EOF
    chmod +x "$YARN_PATH"
  fi
done

# Also wrap yarn in node_modules/.bin if it exists
if [ -f "/calcom/node_modules/.bin/yarn" ] && [ ! -f "/calcom/node_modules/.bin/yarn.real" ]; then
  mv /calcom/node_modules/.bin/yarn /calcom/node_modules/.bin/yarn.real
  cat > /calcom/node_modules/.bin/yarn << 'WRAPPER_EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi
exec "$0.real" "$@"
WRAPPER_EOF
  chmod +x /calcom/node_modules/.bin/yarn
fi

scripts/wait-for-it.sh ${DATABASE_HOST} -- echo "database is up"
npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
yarn start
