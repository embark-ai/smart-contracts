# Script Usage

Foundry scripts in `script/`:

| Script | Purpose |
|---|---|
| `DeployBscMainnet.s.sol` | Deploy factory, LumiaPaymasterV2, TargetRegistry and LumiaPaymasterV3 to BSC Mainnet |
| `ConfigurePaymasterV2.s.sol` | Owner-only configuration of LumiaPaymasterV2 (flags, users, bundlers, gas limits) |
| `ConfigurePaymasterV3.s.sol` | Same for LumiaPaymasterV3, plus `accountFactory` and TargetRegistry projects |
| `FundPaymaster.s.sol` | Add EntryPoint stake and deposit to an existing V2/V3 paymaster |
| `PaymasterConfigLib.sol`, `PaymasterStake.sol` | Shared helpers |

## Prerequisites

- `PRIVATE_KEY` in the environment or `.env` (Foundry loads `.env` automatically). Never commit it.
- `BSC_MAINNET_RPC_URL` for the `bsc_mainnet` alias in `foundry.toml`, e.g. `https://bsc-dataseed.binance.org`.
- BSC requires legacy transactions: pass `--legacy`.
- Run every script without `--broadcast` first to simulate it.

---

## 1) Deploy to BSC Mainnet

**Script:** `script/DeployBscMainnet.s.sol`

```bash
forge script script/DeployBscMainnet.s.sol:DeployBscMainnet \
  --rpc-url bsc_mainnet --broadcast --legacy
```

| Variable | Default | Description |
|---|---|---|
| `PRIVATE_KEY` | — | Deployer; becomes owner of the factory, registry and paymasters |
| `INITIAL_DEPOSIT` | `0` | Wei deposited into each paymaster |
| `PAYMASTER_STAKE` / `PAYMASTER_UNSTAKE_DELAY` | `0` / `86400` | EntryPoint stake for V2 and V3 |
| `USE_USER_ALLOWLIST` / `USE_BUNDLER_ALLOWLIST` / `USE_GAS_LIMITS` | `false` | V2 and V3 flags |
| `USE_PROJECT_ALLOWLIST` | `false` | V3 project allowlist |

The script sets `LumiaPaymasterV3.accountFactory` to the new factory and writes addresses to `deployments/deploy-bsc-mainnet/`.

Keep `INITIAL_DEPOSIT` at `0` and fund the paymasters after configuring the allowlists: with all flags off, a funded paymaster sponsors any `execute` / `executeBatch` of any account (V3: any factory account).

---

## 2) Configure paymaster allowlists

**Scripts:** `script/ConfigurePaymasterV2.s.sol`, `script/ConfigurePaymasterV3.s.sol`

Required env: `PRIVATE_KEY`, `PAYMASTER` (the caller must be the paymaster owner; for V3 project writes also the TargetRegistry owner).

Optional env (empty = skip that step):

| Variable | Meaning |
|---|---|
| `SET_FLAGS=true` | Apply feature flags |
| `USE_USER_ALLOWLIST` / `USE_BUNDLER_ALLOWLIST` / `USE_GAS_LIMITS` | Flag values (V2 and V3) |
| `USE_PROJECT_ALLOWLIST` | V3 only |
| `USERS` / `USER_STATUSES` | Comma-separated addresses; statuses default to `true` |
| `BUNDLERS` / `BUNDLER_STATUSES` | Same for bundlers |
| `GAS_LIMIT_ACCOUNTS` + `GAS_LIMIT` | Wei limit for listed accounts |
| `GAS_LIMIT_RESETTABLE` / `GAS_LIMIT_RESET_PERIOD` | Optional gas-limit shape |
| `RESET_SPENT_ACCOUNTS` | Call `resetAccountSpentGas` |
| `ACCOUNT_FACTORY` | V3: set factory (`0x0…0` clears); omit to leave unchanged |
| `ADD_PROJECTS` | V3: create projects by name if missing |
| `PROJECT_CONTRACTS` | V3: `Name:0xaddr,Name:0xaddr2`; contracts already in the project are skipped |
| `ALLOW_PROJECTS` / `DISALLOW_PROJECTS` | V3: allowlist by project name |
| `TARGET_REGISTRY` | V3: override (default = `paymaster.targetRegistry()`) |

```bash
# V2: bundler allowlist only
PAYMASTER=0x... SET_FLAGS=true \
USE_USER_ALLOWLIST=false USE_BUNDLER_ALLOWLIST=true USE_GAS_LIMITS=false \
BUNDLERS=0xBundler... \
forge script script/ConfigurePaymasterV2.s.sol:ConfigurePaymasterV2 \
  --rpc-url bsc_mainnet --broadcast --legacy

# V3: bundler + project allowlist
PAYMASTER=0x... SET_FLAGS=true \
USE_USER_ALLOWLIST=false USE_BUNDLER_ALLOWLIST=true USE_PROJECT_ALLOWLIST=true USE_GAS_LIMITS=false \
BUNDLERS=0xBundler... \
ADD_PROJECTS=MyDapp PROJECT_CONTRACTS="MyDapp:0xTarget1,MyDapp:0xTarget2" ALLOW_PROJECTS=MyDapp \
forge script script/ConfigurePaymasterV3.s.sol:ConfigurePaymasterV3 \
  --rpc-url bsc_mainnet --broadcast --legacy
```

V3 checks every target of `executeBatch`. If users batch an ERC-20 `approve` with a protocol call, the token contract must be in the project too.

---

## 3) Stake and deposit an existing paymaster

**Script:** `script/FundPaymaster.s.sol` (V2 and V3; the caller must be the paymaster owner).

Run it only after the allowlists are configured.

| Variable | Meaning |
|---|---|
| `PAYMASTER` | Paymaster address (required) |
| `PAYMASTER_STAKE` | Stake in wei; `0` or unset skips `addStake` |
| `PAYMASTER_UNSTAKE_DELAY` | Unstake delay in seconds (default `86400`) |
| `DEPOSIT` | EntryPoint deposit in wei; `0` or unset skips `deposit` |

```bash
PAYMASTER=0x... PAYMASTER_STAKE=5000000000000000 PAYMASTER_UNSTAKE_DELAY=86400 DEPOSIT=50000000000000000 \
forge script script/FundPaymaster.s.sol:FundPaymaster \
  --rpc-url bsc_mainnet --broadcast --legacy
```

V2/V3 return a postOp context, so ERC-7562 compliant bundlers require them to be staked (rule EREP-050). The stake amount and delay depend on the bundler configuration.

---

## Related docs

- [DEPLOYMENT_BSC_MAINNET.md](../DEPLOYMENT_BSC_MAINNET.md) — deployed addresses, configuration, verification
- [FOUNDRY_COMMANDS.md](FOUNDRY_COMMANDS.md) — common Foundry commands
