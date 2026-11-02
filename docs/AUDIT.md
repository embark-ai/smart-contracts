# Auditor Guide

Short orientation for auditors: repository layout, scope, assumptions and known limitations.

## Scope

| Contract | Description |
|----------|-------------|
| **LumiaAccount** | ERC-4337 smart account (eth-infinitism `BaseAccount`), single owner, UUPS restricted to factory-approved implementations, `execute` / `executeBatch` |
| **LumiaAccountFactory** | CREATE2 factory deploying `ERC1967Proxy`; `createAccount(owner, salt)`, `getAddress(owner, salt)`, account registry `isAccount`, owner-managed `isApprovedImplementation` |
| **LumiaPaymasterV2** | Paymaster: user and bundler allowlists, per-account gas limits (reserve-and-settle), `execute` / `executeBatch` parsing |
| **LumiaPaymasterV3** | Same as V2 plus a project-based target allowlist via `TargetRegistry` and an optional sender restriction to factory accounts (`setAccountFactory`) |
| **TargetRegistry** | Registry of projects (`keccak256(name)` → bit index) and contract membership bitmaps; owner-only |
| **PaymasterCallDataParser** | Library parsing `execute(address,uint256,bytes)` and `executeBatch(address[],uint256[],bytes[])`, `MAX_BATCH_SIZE = 100` |

Events and errors are declared in `src/interfaces/` (one interface per contract) and inherited by the contracts.

Dependencies: **account-abstraction** (EntryPoint v0.7, `BaseAccount`, `BasePaymaster`), **OpenZeppelin 4.9.6** (proxy, `Ownable`, `ECDSA`, `UUPSUpgradeable`).

## Assumptions

- EntryPoint is the canonical ERC-4337 v0.7 deployment at `0x0000000071727De22E5E9d8BAf0edAc6f37da032`.
- `LumiaPaymasterV2/V3` skip the ERC-165 EntryPoint check (`_validateEntryPointInterface` is empty) for compatibility with chains whose EntryPoint deployment does not report ERC-165 support (e.g. Lumia Beam).
- The paymaster does not check its deposit in `validatePaymasterUserOp`; EntryPoint does it.
- If `callData` cannot be parsed (unsupported selector, malformed ABI, batch > 100, inconsistent batch array lengths), V2 always and V3 with `useProjectAllowlist` revert with `CallDataParseFailed()` (or `InvalidCallData()` / an ABI decoder revert for malformed `execute`).
- `paymasterAndData` follows the v0.7 layout (at least 52 bytes); the paymasters read `paymasterPostOpGasLimit` from it when a gas limit applies.
- V2/V3 return a non-empty context and must be **staked** in the EntryPoint to be accepted by ERC-7562 compliant bundlers. Deployment scripts stake via `PAYMASTER_STAKE` / `PAYMASTER_UNSTAKE_DELAY` (default 0 = no stake, see `script/PaymasterStake.sol`).

## Known Limitations and Design Decisions

### Gas limit accounting (reserve-and-settle)

Validation reserves `maxCost` in `accountSpentGas`; `postOp` releases `maxCost - (actualGasCost + unaccountedGas * gasPrice)`, where `unaccountedGas` bounds the postOp gas, EntryPoint overhead and the unused-gas penalty that EntryPoint adds after `postOp`. Consequences:

- The limit is strict within a bundle (each validation sees previous reservations).
- An undersized `paymasterPostOpGasLimit` cannot roll back accounting: if `postOp` does not run, the full reservation stays charged (self-inflicted budget loss for the user).
- The counter is conservative (may exceed the real outflow by up to `unaccountedGas * gasPrice` per UserOp).

See `docs/IMPLEMENTATION_NOTES.md`.

### Empty batches (V3)

With `useProjectAllowlist` enabled, `executeBatch` with an empty `dest` array is rejected. With the flag disabled, targets are not inspected and empty batches are sponsored (same as V2); use user allowlists or gas limits to bound abuse.

### Registry change (V3)

`setTargetRegistry` clears `allowedProjectsBitmap`, because bit indices are specific to a registry instance. Projects must be re-allowed after the switch.

### Account upgrade via self-call

`LumiaAccount._onlyOwner` accepts `msg.sender == owner` **or** `msg.sender == address(this)`. `_authorizeUpgrade` uses this check, and OpenZeppelin 4.9.6 exposes `upgradeTo` / `upgradeToAndCall` publicly. Therefore the owner can upgrade the account with a regular UserOp:

```
callData = execute(account, 0, upgradeToAndCall(newImplementation, data))
```

This is the intended upgrade path (same as eth-infinitism `SimpleAccount`) and requires a valid owner signature. `_authorizeUpgrade` additionally requires `factory.isApprovedImplementation(newImplementation)`, so an account can only switch to implementations approved by the factory owner (reverts with `UnapprovedImplementation` otherwise). Implications that integrators must be aware of:

- Anyone who can obtain an owner signature can still upgrade, but only to an approved implementation; arbitrary code is not reachable.
- The factory owner is trusted: every approved implementation must keep the factory-restricted `_authorizeUpgrade`, otherwise registered accounts could escape to arbitrary code.
- `LumiaPaymasterV3` relies on this when `setAccountFactory` is set: only `factory.isAccount(sender)` senders are sponsored, so the parsed targets are the targets the account will call. Without it, a selector-compatible custom account passes the project allowlist (see `testLow_SelectorCompatibleAccountSponsoredWithoutFactoryCheck`).

Recommended off-chain mitigation remains: the signing service should refuse to sign UserOps whose target is the sender itself with `upgradeTo` / `upgradeToAndCall` selectors, unless it is a planned migration.

### Audit scan 6821846

Full report: [docs/audits/scan-lumiaid-aa-demo-contracts-audit-6821846-f96094a6.md](audits/scan-lumiaid-aa-demo-contracts-audit-6821846-f96094a6.md).

| Finding | Severity | Fix | Tests |
|---|---|---|---|
| User-controlled postOp gas can roll back spend accounting | High | Reserve `maxCost` in validation | `testHigh_*` |
| Gas counter omits post-operation cost and unused-gas penalty | Medium | Charge `actualGasCost + unaccountedGas * gasPrice` in `postOp` | `testMedium_*` |
| Project allowlist does not bind parsed targets to the sender's execution | Low | Factory account registry + upgrades restricted to approved implementations + `LumiaPaymasterV3.setAccountFactory` | `testLow_*Factory*`, `testLow_SelectorCompatible*` |
| Truncated execute calldata passes paymaster parsing | Low | Full ABI decoding of `execute`, batch array length checks | `testLow_TruncatedExecute*`, `testLow_BatchLengthMismatch*` |
| Deferred gas accounting allows bundled UserOps to exceed a limit | Info | Same reservation as High | `testInfo_*` |

All end-to-end tests are in `test/AuditFixes.t.sol` and run through a real EntryPoint v0.7 (compiled from `lib/account-abstraction` with a context remapping for OZ 4.9.6 `ReentrancyGuard`, see `foundry.toml`).

## How to Run

```bash
# Build
forge build

# All tests
forge test

# In-scope tests only
forge test --match-contract "LumiaAccountTest|LumiaPaymasterV2Test|LumiaPaymasterV3Test|TargetRegistryTest|PaymasterCallDataParserTest|AuditFixesTest"

# End-to-end audit fix tests through EntryPoint v0.7
forge test --match-contract AuditFixesTest -vv

# Gas report
forge test --gas-report

# Fuzz tests (included in forge test)
forge test --match-test "testFuzz"
```

Fork tests (`LumiaPaymasterForkTest`) fork BSC Mainnet and need RPC access (`BSC_MAINNET_RPC_URL`, defaults to the public BSC endpoint).

## Layout

- `src/` — in-scope contracts and helpers.
- `src/interfaces/` — events and errors per contract.
- `test/` — tests; file names match contracts.
- `script/` — Foundry deployment scripts; `PaymasterStake.sol` is the shared staking helper.
- `lib/` — `openzeppelin-contracts` (v4.9.6) and `forge-std` as git submodules; `account-abstraction` v0.7.0 is vendored with a one-line OZ 4.9.6 compatibility patch in `BasePaymaster` (see `lib/account-abstraction/PATCHES.md`).
- `docs/` — documentation; `docs/PAYMASTER_BACKEND_INTEGRATION.md` describes paymaster integration, `docs/IMPLEMENTATION_NOTES.md` covers design details, `docs/ACCOUNTS_CHANGELOG.md` lists account and factory changes between versions.

## Solidity Version

- All in-scope contracts use `pragma solidity =0.8.28`.
- `foundry.toml`: `solc = "0.8.28"`, `optimizer_runs = 200`, `evm_version = "shanghai"`.

## Invariants

- **Factory**: for the same `(owner, salt)`, `getAddress(owner, salt)` equals the address returned by `createAccount(owner, salt)`; repeated `createAccount` returns the same address. `isAccount[a]` is true iff `a` was deployed by `createAccount`.
- **Account**: the implementation of a factory account is always an implementation that was approved by the factory at upgrade time.
- **TargetRegistry**: a contract may belong to several projects; bit `i` of `contractBitmap[addr]` is set iff `addr` is in the project with bit index `i`. `isContractInProject` is true iff that bit is set and the project is active. Bit indices are never reused.
- **LumiaPaymasterV3**: a target passes iff `contractBitmap[target] & activeProjectsBitmap & allowedProjectsBitmap != 0`.
- **LumiaPaymasterV3**: with `accountFactory != 0`, validation succeeds only if `accountFactory.isAccount(sender)`.
- **Paymaster**: `validatePaymasterUserOp` does not change the deposit; when a gas limit applies it only writes `accountSpentGas[sender]` (reservation) and `accountGasLimitInfo[sender].lastResetTime` (auto-reset). `accountSpentGas` never exceeds `limit`, and after `postOp` (or without it) the recorded increase per UserOp is at least the amount EntryPoint charged the deposit and at most `maxCost`.
