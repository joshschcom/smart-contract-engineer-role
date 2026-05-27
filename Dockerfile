FROM node:20

WORKDIR /app

# Install curl for healthcheck
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Upgrade npm to fix semver parsing bug in 10.x
RUN npm install -g npm@latest

# Install root deps (no lockfile — avoids corrupted lock from WSL installs)
COPY package.json ./
RUN npm install

# Install contract deps
COPY contracts/package.json ./contracts/
RUN npm install --prefix contracts

# Copy source
COPY . .

RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 3000 8545

ENTRYPOINT ["/app/docker-entrypoint.sh"]
