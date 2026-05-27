# ChainQuest — Submission

**Name:** Joshua Schiemann  
**Email:** joshuaschiemann@googlemail.com  
**GitHub:** https://github.com/joshschcom/smart-contract-engineer-role

---

## Contract Addresses (Hardhat localhost)

| Contract | Address |
|---|---|
| QuestEscrow | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| Mock USDC | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| Chain ID | `31337` |

---

## What was implemented

**Part A — `contracts/contracts/QuestEscrow.sol`**  
Full escrow contract with ETH and ERC20 support, 3% platform fee, accept/submit/approve lifecycle, worker timeout payout, poster cancel and refund paths. All 9 assessment scenarios pass.

**Part B — `lib/hooks/useQuestEscrow.ts`**  
Implemented `useCreateQuest` and `useQuestActions` using wagmi's `useWriteContract` and `useWaitForTransactionReceipt`. All wallet actions (create, accept, submit, approve, claimTimeout, cancel, refund) send real on-chain transactions and track pending state.

---

## How to run

### With Docker (recommended)

Requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) running.

```bash
docker compose up --build
```

This automatically:
1. Starts a local Hardhat node on port 8545
2. Compiles and deploys `QuestEscrow` + `MockERC20`
3. Writes contract addresses to `.env.local`
4. Starts the Next.js UI on port 3000

Open **http://localhost:3000** (or the port shown in Docker Desktop if remapped).

In your Web3 wallet, add the network:
- **RPC URL:** `http://127.0.0.1:8545`
- **Chain ID:** `31337`

Import test accounts using Hardhat's default private keys:
- Account A (poster): `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
- Account B (worker): `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d`

### Without Docker (standard)

```bash
npm install
npm install --prefix contracts

# Terminal 1
npm run contracts:node

# Terminal 2
npm run contracts:deploy
# Copy printed addresses into .env.local

# Terminal 3
npm run dev
```

---

## Development notes

Development was done on WSL2 (Ubuntu on Windows). The standard `npm run dev` setup ran into two native binary incompatibilities caused by the WSL2 kernel lacking certain CPU instruction sets:

- `@next/swc-linux-x64-gnu` — Next.js's Rust-based compiler crashed on load (SIGBUS)
- `lightningcss-linux-x64-gnu` — Tailwind v4's CSS processor crashed the same way

Rather than hacking around these limitations further, the project was containerised with Docker. Running inside a Docker container on Windows gives the full host CPU instruction set, so all native binaries work without modification. The Docker setup also automates the full local workflow (Hardhat node + contract deployment + Next.js) into a single `docker compose up --build` command.

---

## Security considerations

### Protections in place

| Concern | Mitigation |
| Reentrancy | All fund-moving functions use OpenZeppelin's `nonReentrant` modifier |
| Checks-Effects-Interactions | Quest status is written to storage *before* any ETH or token transfer, so a reentrant call re-enters with an already-updated state and hits a status revert |
| Access control | Every action is gated to the correct role: only poster can approve/cancel/refund, only worker can submit/claimTimeout, only owner can withdraw fees |
| ERC20 safety | `SafeERC20` wraps all token calls, handling tokens that return `false` instead of reverting (e.g. USDT) |
| Integer overflow | Solidity 0.8+ reverts on overflow by default; no `unchecked` blocks used |
| Fee pull model | Fees accumulate in `availableFees` storage and are explicitly pulled by the owner via `withdrawFees`, avoiding a failed-push DoS that could block user transactions |

### Known limitations / accepted risks

**ETH receiver DoS** — if the worker is a contract that reverts on ETH receive, `approveAndPay` and `claimTimeoutPayout` will revert, temporarily locking the reward. The poster retains an escape hatch: once the review window expires, `refundPoster` returns the full reward so funds are never permanently locked.

**Fee-on-transfer tokens** — the contract records `reward` as the nominal amount the poster passes in. Tokens that silently deduct a transfer fee mean the contract holds less than `reward`, causing payout arithmetic to over-draw. Such tokens are not supported.

**Front-running `acceptQuest`** — two workers racing to accept the same quest will see one succeed and one revert (the quest status is no longer `Open`). No funds are at risk; it is a UX inconvenience only.

---

## Screenshots

See `assets/` for screenshots of the complete Part C UI flow:
- Wallet connected in header
- Quest created and visible on the board (Open)
- Quest accepted by worker
- Deliverable submitted
- Approved and paid (Completed)
- Worker balance reflecting 97% payout
