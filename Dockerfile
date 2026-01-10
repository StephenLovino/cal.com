FROM --platform=$BUILDPLATFORM node:20 AS builder

WORKDIR /calcom

## If we want to read any ENV variable from .env file, we need to first accept and pass it as an argument to the Dockerfile
ARG NEXT_PUBLIC_LICENSE_CONSENT
ARG NEXT_PUBLIC_WEBSITE_TERMS_URL
ARG NEXT_PUBLIC_WEBSITE_PRIVACY_POLICY_URL
ARG CALCOM_TELEMETRY_DISABLED
ARG DATABASE_URL
ARG NEXTAUTH_SECRET=secret
ARG CALENDSO_ENCRYPTION_KEY=secret
ARG MAX_OLD_SPACE_SIZE=6144
ARG NEXT_PUBLIC_API_V2_URL
ARG CSP_POLICY

## We need these variables as required by Next.js build to create rewrites
ARG NEXT_PUBLIC_SINGLE_ORG_SLUG
ARG ORGANIZATIONS_ENABLED

ENV NEXT_PUBLIC_WEBAPP_URL=http://NEXT_PUBLIC_WEBAPP_URL_PLACEHOLDER \
    NEXT_PUBLIC_API_V2_URL=$NEXT_PUBLIC_API_V2_URL \
    NEXT_PUBLIC_LICENSE_CONSENT=$NEXT_PUBLIC_LICENSE_CONSENT \
    NEXT_PUBLIC_WEBSITE_TERMS_URL=$NEXT_PUBLIC_WEBSITE_TERMS_URL \
    NEXT_PUBLIC_WEBSITE_PRIVACY_POLICY_URL=$NEXT_PUBLIC_WEBSITE_PRIVACY_POLICY_URL \
    CALCOM_TELEMETRY_DISABLED=$CALCOM_TELEMETRY_DISABLED \
    DATABASE_URL=$DATABASE_URL \
    DATABASE_DIRECT_URL=$DATABASE_URL \
    NEXTAUTH_SECRET=${NEXTAUTH_SECRET} \
    CALENDSO_ENCRYPTION_KEY=${CALENDSO_ENCRYPTION_KEY} \
    NEXT_PUBLIC_SINGLE_ORG_SLUG=$NEXT_PUBLIC_SINGLE_ORG_SLUG \
    ORGANIZATIONS_ENABLED=$ORGANIZATIONS_ENABLED \
    NODE_OPTIONS=--max-old-space-size=${MAX_OLD_SPACE_SIZE} \
    BUILD_STANDALONE=true \
    CSP_POLICY=$CSP_POLICY

COPY package.json yarn.lock .yarnrc.yml playwright.config.ts turbo.json i18n.json ./
COPY .yarn ./.yarn
COPY apps/web ./apps/web
COPY apps/api/v2 ./apps/api/v2
COPY packages ./packages
COPY tests ./tests

RUN yarn config set httpTimeout 1200000
RUN yarn plugin import npm-cli || true
RUN npx turbo prune --scope=@calcom/web --scope=@calcom/trpc --docker
RUN yarn install
# Build and make embed servable from web/public/embed folder
RUN yarn workspace @calcom/trpc run build
RUN yarn --cwd packages/embeds/embed-core workspace @calcom/embed-core run build
RUN touch apps/web/.env
RUN yarn --cwd apps/web workspace @calcom/web run build
# Install SWC binary for linux-x64-gnu directly in node_modules
# This ensures Next.js finds it and doesn't try to download at runtime
# Force installation even on different arch using npm pack + extract
RUN NEXT_VERSION=$(node -p "require('./node_modules/next/package.json').version") && \
    mkdir -p node_modules/@next/swc-linux-x64-gnu && \
    cd /tmp && \
    npm pack @next/swc-linux-x64-gnu@$NEXT_VERSION && \
    tar -xzf next-swc-linux-x64-gnu-*.tgz && \
    cp -r package/* /calcom/node_modules/@next/swc-linux-x64-gnu/ && \
    rm -rf /tmp/package /tmp/*.tgz || true
RUN rm -rf node_modules/.cache .yarn/cache apps/web/.next/cache

FROM node:20 AS builder-two

WORKDIR /calcom
ARG NEXT_PUBLIC_WEBAPP_URL=http://localhost:3000

ENV NODE_ENV=production

COPY package.json .yarnrc.yml turbo.json i18n.json ./
COPY .yarn ./.yarn
COPY --from=builder /calcom/yarn.lock ./yarn.lock
# Try to install npm-cli plugin, but don't fail if it doesn't work (we have a fallback)
RUN yarn plugin import npm-cli 2>/dev/null || \
    (mkdir -p .yarn/plugins/@yarnpkg && \
     curl -fsSL https://raw.githubusercontent.com/yarnpkg/berry/master/packages/plugin-npm-cli/bundles/@yarnpkg/plugin-npm-cli.js -o .yarn/plugins/@yarnpkg/plugin-npm-cli.cjs 2>/dev/null || true) || true
COPY --from=builder /calcom/node_modules ./node_modules
COPY --from=builder /calcom/packages ./packages
COPY --from=builder /calcom/apps/web ./apps/web
COPY --from=builder /calcom/packages/prisma/schema.prisma ./prisma/schema.prisma
COPY scripts scripts
RUN chmod +x scripts/*

# Save value used during this build stage. If NEXT_PUBLIC_WEBAPP_URL and BUILT_NEXT_PUBLIC_WEBAPP_URL differ at
# run-time, then start.sh will find/replace static values again.
ENV NEXT_PUBLIC_WEBAPP_URL=$NEXT_PUBLIC_WEBAPP_URL \
    BUILT_NEXT_PUBLIC_WEBAPP_URL=$NEXT_PUBLIC_WEBAPP_URL

RUN scripts/replace-placeholder.sh http://NEXT_PUBLIC_WEBAPP_URL_PLACEHOLDER ${NEXT_PUBLIC_WEBAPP_URL}

FROM node:20 AS runner

WORKDIR /calcom

RUN apt-get update && apt-get install -y --no-install-recommends netcat-openbsd wget && rm -rf /var/lib/apt/lists/*

COPY --from=builder-two /calcom ./
ARG NEXT_PUBLIC_WEBAPP_URL=http://localhost:3000
ENV NEXT_PUBLIC_WEBAPP_URL=$NEXT_PUBLIC_WEBAPP_URL \
    BUILT_NEXT_PUBLIC_WEBAPP_URL=$NEXT_PUBLIC_WEBAPP_URL \
    npm_config_registry=https://registry.npmjs.org/

# ALWAYS ensure SWC binary is installed in runner stage
# This is critical for Next.js to work without downloading SWC at runtime
# We install it here regardless of COPY to ensure it's always present
RUN echo "Installing SWC binary for linux-x64-gnu..." && \
    NEXT_VERSION=$(node -p "require('./node_modules/next/package.json').version" 2>/dev/null || echo "16.1.0") && \
    mkdir -p /calcom/node_modules/@next/swc-linux-x64-gnu && \
    cd /tmp && \
    npm pack @next/swc-linux-x64-gnu@$NEXT_VERSION 2>&1 && \
    tar -xzf next-swc-linux-x64-gnu-*.tgz && \
    cp -r package/* /calcom/node_modules/@next/swc-linux-x64-gnu/ && \
    rm -rf /tmp/package /tmp/*.tgz && \
    ls -lh /calcom/node_modules/@next/swc-linux-x64-gnu/next-swc.linux-x64-gnu.node && \
    echo "SWC binary installed successfully"

# Ensure npm-cli plugin is installed and working (this makes yarn config get registry work natively)
RUN if [ ! -f .yarn/plugins/@yarnpkg/plugin-npm-cli.cjs ]; then \
      mkdir -p .yarn/plugins/@yarnpkg && \
      curl -fsSL https://raw.githubusercontent.com/yarnpkg/berry/master/packages/plugin-npm-cli/bundles/@yarnpkg/plugin-npm-cli.js -o .yarn/plugins/@yarnpkg/plugin-npm-cli.cjs || true; \
    fi

# Also set up yarn wrapper as fallback (in case plugin doesn't work or Next.js bypasses it)
# Wrap /usr/local/bin/yarn (the system yarn) - always ensure wrapper exists
RUN if [ -f /usr/local/bin/yarn ] && [ ! -f /usr/local/bin/yarn.real ]; then \
      mv /usr/local/bin/yarn /usr/local/bin/yarn.real; \
    fi
RUN cat > /usr/local/bin/yarn << 'EOF'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then
  echo "[yarn-wrapper] Intercepted: yarn config get registry" >&2
  echo "${npm_config_registry:-https://registry.npmjs.org/}"
  exit 0
fi
exec /usr/local/bin/yarn.real "$@"
EOF
RUN chmod +x /usr/local/bin/yarn

# Wrap /calcom/node_modules/.bin/yarn (where Next.js might call it from)
# Handle both regular files and symlinks
RUN if [ -L /calcom/node_modules/.bin/yarn ]; then \
      REAL_YARN=$(readlink -f /calcom/node_modules/.bin/yarn 2>/dev/null || readlink /calcom/node_modules/.bin/yarn) && \
      rm /calcom/node_modules/.bin/yarn && \
      (cp "$REAL_YARN" /calcom/node_modules/.bin/yarn.real 2>/dev/null || \
       cp /usr/local/bin/yarn.real /calcom/node_modules/.bin/yarn.real); \
    elif [ -f /calcom/node_modules/.bin/yarn ] && [ ! -f /calcom/node_modules/.bin/yarn.real ]; then \
      mv /calcom/node_modules/.bin/yarn /calcom/node_modules/.bin/yarn.real; \
    fi
RUN if [ -f /calcom/node_modules/.bin/yarn.real ]; then \
      printf '#!/bin/sh\nif [ "$1" = "config" ] && [ "$2" = "get" ] && [ "$3" = "registry" ]; then\n  echo "[yarn-wrapper] Intercepted: yarn config get registry" >&2\n  echo "${npm_config_registry:-https://registry.npmjs.org/}"\n  exit 0\nfi\nexec /calcom/node_modules/.bin/yarn.real "$@"\n' > /calcom/node_modules/.bin/yarn && \
      chmod +x /calcom/node_modules/.bin/yarn; \
    fi

ENV NODE_ENV=production
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD wget --spider --quiet http://localhost:3000 || exit 1

CMD ["/calcom/scripts/start.sh"]
