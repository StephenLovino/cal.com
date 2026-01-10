#!/bin/sh
set -x

# Replace the statically built BUILT_NEXT_PUBLIC_WEBAPP_URL with run-time NEXT_PUBLIC_WEBAPP_URL
# NOTE: if these values are the same, this will be skipped.
scripts/replace-placeholder.sh "$BUILT_NEXT_PUBLIC_WEBAPP_URL" "$NEXT_PUBLIC_WEBAPP_URL"

# Ensure SWC binary is installed at runtime (fallback if build-time installation was cached/skipped)
# This MUST happen before yarn start, as Next.js needs it immediately
if [ ! -f /calcom/node_modules/@next/swc-linux-x64-gnu/next-swc.linux-x64-gnu.node ]; then
  echo "=== SWC binary missing at runtime, installing now ==="
  NEXT_VERSION=$(node -p "require('./node_modules/next/package.json').version" 2>/dev/null || echo "16.1.0")
  mkdir -p /calcom/node_modules/@next/swc-linux-x64-gnu
  cd /tmp
  npm pack @next/swc-linux-x64-gnu@$NEXT_VERSION 2>&1
  tar -xzf next-swc-linux-x64-gnu-*.tgz
  cp -r package/* /calcom/node_modules/@next/swc-linux-x64-gnu/
  rm -rf /tmp/package /tmp/*.tgz
  ls -lh /calcom/node_modules/@next/swc-linux-x64-gnu/next-swc.linux-x64-gnu.node
  echo "=== SWC binary installed at runtime ==="
else
  echo "=== SWC binary already present ==="
fi

# Set up yarn wrapper to handle "yarn config get registry" for Next.js SWC download
# This fixes the issue where Yarn 4 doesn't support this command without npm-cli plugin
# IMPORTANT: This must be done BEFORE yarn start, as Next.js calls yarn during SWC download
# The Dockerfile already sets up wrappers, but we ensure they're active here too

# Wrap /usr/local/bin/yarn if not already wrapped (preserve Dockerfile wrapper if it exists)
if [ -f /usr/local/bin/yarn ] && [ ! -f /usr/local/bin/yarn.real ]; then
  mv /usr/local/bin/yarn /usr/local/bin/yarn.real
fi
# Always ensure wrapper exists (even if .real already exists from Dockerfile)
cat > /usr/local/bin/yarn << 'WRAPPER_EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  echo "[yarn-wrapper] Intercepted: yarn config get registry" >&2
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi
exec /usr/local/bin/yarn.real "$@"
WRAPPER_EOF
chmod +x /usr/local/bin/yarn

# Wrap /calcom/node_modules/.bin/yarn (where Next.js might call it from)
if [ -L /calcom/node_modules/.bin/yarn ]; then
  # Handle symlink - resolve and backup
  REAL_YARN=$(readlink -f /calcom/node_modules/.bin/yarn 2>/dev/null || readlink /calcom/node_modules/.bin/yarn)
  rm /calcom/node_modules/.bin/yarn
  if [ -f "$REAL_YARN" ]; then
    cp "$REAL_YARN" /calcom/node_modules/.bin/yarn.real 2>/dev/null || cp /usr/local/bin/yarn.real /calcom/node_modules/.bin/yarn.real
  else
    cp /usr/local/bin/yarn.real /calcom/node_modules/.bin/yarn.real
  fi
elif [ -f /calcom/node_modules/.bin/yarn ] && [ ! -f /calcom/node_modules/.bin/yarn.real ]; then
  mv /calcom/node_modules/.bin/yarn /calcom/node_modules/.bin/yarn.real
fi
# Always ensure wrapper exists
if [ -f /calcom/node_modules/.bin/yarn.real ]; then
  cat > /calcom/node_modules/.bin/yarn << 'WRAPPER_EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  echo "[yarn-wrapper] Intercepted: yarn config get registry" >&2
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi
exec /calcom/node_modules/.bin/yarn.real "$@"
WRAPPER_EOF
  chmod +x /calcom/node_modules/.bin/yarn
fi

scripts/wait-for-it.sh ${DATABASE_HOST} -- echo "database is up"
npx prisma migrate deploy --schema /calcom/packages/prisma/schema.prisma
npx ts-node --transpile-only /calcom/scripts/seed-app-store.ts
yarn start
