#!/bin/bash
set -e

echo "==> Starting Hardhat node..."
cd /app/contracts
npx hardhat node --hostname 0.0.0.0 > /tmp/hardhat.log 2>&1 &

echo "==> Waiting for Hardhat RPC..."
until curl -s -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' > /dev/null 2>&1; do
  sleep 1
done
echo "==> Hardhat ready."

echo "==> Deploying contracts..."
DEPLOY_OUTPUT=$(npx hardhat run scripts/deploy.ts --network localhost 2>&1)
echo "$DEPLOY_OUTPUT"

ESCROW_ADDR=$(echo "$DEPLOY_OUTPUT" | grep "NEXT_PUBLIC_QUEST_ESCROW_ADDRESS=" | cut -d= -f2 | tr -d '[:space:]')
USDC_ADDR=$(echo "$DEPLOY_OUTPUT" | grep "NEXT_PUBLIC_MOCK_USDC_ADDRESS=" | cut -d= -f2 | tr -d '[:space:]')

echo "==> Escrow:    $ESCROW_ADDR"
echo "==> Mock USDC: $USDC_ADDR"

cat > /app/.env.local << EOF
NEXT_PUBLIC_QUEST_ESCROW_ADDRESS=$ESCROW_ADDR
NEXT_PUBLIC_MOCK_USDC_ADDRESS=$USDC_ADDR
NEXT_PUBLIC_CHAIN_ID=31337
NEXT_PUBLIC_RPC_URL=http://127.0.0.1:8545
EOF

echo "==> Starting Next.js..."
cd /app
exec npx next dev -H 0.0.0.0
