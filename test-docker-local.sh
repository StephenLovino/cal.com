#!/bin/bash
# Script to test the Docker image locally before deploying to Easypanel

set -e

echo "🐳 Building Docker image..."
docker build \
  --build-arg NEXT_PUBLIC_WEBAPP_URL=http://localhost:3000 \
  --build-arg NEXTAUTH_SECRET=test-secret-change-in-production \
  --build-arg CALENDSO_ENCRYPTION_KEY=test-encryption-key-change-in-production \
  --build-arg DATABASE_URL=postgresql://test:test@database:5432/testdb \
  -t calcom-test:local .

echo ""
echo "🗄️  Starting PostgreSQL database..."
docker run -d \
  --name calcom-test-db \
  -e POSTGRES_USER=unicorn_user \
  -e POSTGRES_PASSWORD=magical_password \
  -e POSTGRES_DB=calendso \
  postgres:latest

echo "⏳ Waiting for database to be ready..."
sleep 5

echo ""
echo "🚀 Starting Cal.com container..."
docker run -d \
  --name calcom-test-app \
  --link calcom-test-db:database \
  -p 3000:3000 \
  -e DATABASE_URL=postgresql://unicorn_user:magical_password@database:5432/calendso \
  -e DATABASE_DIRECT_URL=postgresql://unicorn_user:magical_password@database:5432/calendso \
  -e DATABASE_HOST=database:5432 \
  -e NEXTAUTH_SECRET=test-secret-change-in-production \
  -e CALENDSO_ENCRYPTION_KEY=test-encryption-key-change-in-production \
  -e NEXT_PUBLIC_WEBAPP_URL=http://localhost:3000 \
  calcom-test:local

echo ""
echo "⏳ Waiting for app to start (this may take a minute)..."
sleep 10

echo ""
echo "📋 Container logs (last 50 lines):"
docker logs --tail 50 calcom-test-app

echo ""
echo "✅ Test setup complete!"
echo ""
echo "🌐 App should be available at: http://localhost:3000"
echo ""
echo "To view logs: docker logs -f calcom-test-app"
echo "To stop and clean up: ./test-docker-local.sh cleanup"
echo ""

# Handle cleanup
if [ "$1" = "cleanup" ]; then
  echo "🧹 Cleaning up test containers..."
  docker stop calcom-test-app calcom-test-db 2>/dev/null || true
  docker rm calcom-test-app calcom-test-db 2>/dev/null || true
  echo "✅ Cleanup complete!"
fi

