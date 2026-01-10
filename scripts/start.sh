#!/bin/sh
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

# Set up yarn wrapper to handle "yarn config get registry" for Next.js SWC download
# This fixes the issue where Yarn 4 doesn't support this command without npm-cli plugin
# Find the real yarn binary and back it up, then create a wrapper
REAL_YARN=$(command -v yarn || echo "/usr/local/bin/yarn")
if [ -f "$REAL_YARN" ] && [ ! -f "${REAL_YARN}.real" ]; then
  mv "$REAL_YARN" "${REAL_YARN}.real"
fi

# Create wrapper script that intercepts "yarn config get registry"
cat > "$REAL_YARN" << 'EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi
exec /usr/local/bin/yarn.real "$@"
EOF
chmod +x "$REAL_YARN"

scripts/wait-for-it.sh ${DATABASE_HOST} -- echo "database is up"
npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
yarn start
