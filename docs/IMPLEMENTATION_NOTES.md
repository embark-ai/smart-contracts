# Implementation Notes

This document covers design decisions and implementation details relevant to security auditors and integrators.

## Gas Limit Tracking: Reserve in Validation, Settle in PostOp

### Architecture

Gas limit enforcement in `LumiaPaymasterV2` and `LumiaPaymasterV3` uses reserve-and-settle accounting:

1. **`_validatePaymasterUserOp`** — applies a due auto-reset, checks `accountSpentGas + maxCost <= limit`, then **reserves** `maxCost` by writing `accountSpentGas += maxCost`. Returns context `abi.encode(sender, maxCost, unaccountedGas)`.
2. **`_postOp`** — computes `charge = actualGasCost + unaccountedGas * actualUserOpFeePerGas` and releases `maxCost - charge` if positive. The counter is never increased in `postOp`.

`unaccountedGas` is computed in validation from the UserOp:

```
unaccountedGas = postOpGasLimit + POST_OP_OVERHEAD_GAS + (callGasLimit + postOpGasLimit) * 10 / 100
```

It is an upper bound of what EntryPoint v0.7 adds **after** computing the `actualGasCost` passed to `postOp`: the gas used by `postOp` itself (at most `postOpGasLimit`), EntryPoint overhead around the call (`POST_OP_OVERHEAD_GAS = 15_000`), and the 10% penalty on unused execution gas (at most 10% of `callGasLimit + postOpGasLimit`). The final deposit charge is also bounded by `maxCost` (the prefund). Therefore the recorded spend is always **greater than or equal to** the real deposit outflow, and `accountSpentGas` never exceeds `limit`.

### Why reservation (audit scan 6821846)

The previous design (view-only check in validation, increment in `postOp`) had three accounting gaps, all closed by reservation:

- **Undersized `paymasterPostOpGasLimit` (High).** The postOp gas limit is chosen and signed by the user. With a too small value, `postOp` runs out of gas, EntryPoint reverts the inner call (rolling back the counter update), charges the paymaster in `postOpReverted` mode and never calls `postOp` again. The counter stayed unchanged, so the limit could be bypassed indefinitely. Now the reservation is written in validation, which is not rolled back; if `postOp` does not run, the full `maxCost` stays charged.
- **Preliminary `actualGasCost` (Medium).** `postOp` receives a cost computed before its own gas, the EntryPoint overhead and the unused-gas penalty are added. Recording that value under-reported the real outflow (about 3x in tests with an oversized `callGasLimit`). Now `postOp` adds the `unaccountedGas` upper bound.
- **Several UserOps of one sender in a bundle (Info).** EntryPoint v0.7 validates every UserOp of a bundle before executing any of them. Each validation now sees the reservations of the previous ones, so the limit is strict within a bundle.

Costs and trade-offs:

- Validation writes `accountSpentGas[sender]` (one SSTORE). This is sender-associated storage and allowed by ERC-7562.
- If `postOp` does not run, the user loses `maxCost - actualCost` of budget. This only happens when the UserOp sets an insufficient `paymasterPostOpGasLimit`, i.e. it is self-inflicted.
- The counter is conservative: it may record up to `unaccountedGas * gasPrice` more than the real outflow, mostly from the penalty bound for an oversized `callGasLimit`.

Covered by `test/AuditFixes.t.sol` (end-to-end through EntryPoint v0.7) and by `testValidationReservesMaxCost`, `testSameBundleOpsSeePreviousReservation`, `testPostOpChargesUnaccountedGas` in the paymaster unit tests.

### Resettable Limits

The auto-reset (`_maybeResetGasLimit`) runs in validation, before the reservation, so the reservation is never wiped by a later reset in the same transaction.

### PostOp Modes

`postOp` settles the reservation for **`opSucceeded`** and **`opReverted`** alike. In EntryPoint v0.7 **`postOpReverted`** is never passed to the paymaster (if `postOp` reverts, EntryPoint charges the paymaster without calling it again); in that case the reservation stays charged.

## Account Registry and Restricted Upgrades

### Problem (audit scan 6821846, Low)

`LumiaPaymasterV3` derives the targets of a UserOp from `userOp.callData` by selector. EntryPoint, however, forwards that calldata to `userOp.sender`, whose code decides what is executed. A selector-compatible custom account, or a `LumiaAccount` upgraded to a different implementation, could pass the project allowlist while executing arbitrary logic paid by the paymaster. A code hash check does not help: every `ERC1967Proxy` has the same runtime code, and the implementation lives in storage.

### Solution

- `LumiaAccountFactory` records every deployed account in `isAccount[account]` and keeps an owner-managed set `isApprovedImplementation[impl]`. The base implementation is approved in the constructor; the deployer becomes the factory owner.
- `LumiaAccount` stores its factory as an immutable and `_authorizeUpgrade` reverts with `UnapprovedImplementation` unless the factory approves the new implementation.
- `LumiaPaymasterV3.setAccountFactory(factory)` makes validation return `SIG_VALIDATION_FAILED` for senders that are not `factory.isAccount(sender)`. `address(0)` disables the check. The factory address is packed into the flags slot.

With the factory set, a sponsored sender is guaranteed to run an approved implementation, so the parsed targets are the targets that will be called.

Requirements and consequences:

- Every implementation approved in the factory **must** keep the factory-restricted `_authorizeUpgrade`; otherwise a registered account could escape to arbitrary code.
- Revoking an implementation only blocks future upgrades to it; accounts already running it are not affected.
- The new constructor (`LumiaAccount(entryPoint, factory)`) changes the implementation, so accounts of the new factory get **new addresses**. Accounts of previous factories are not registered and are rejected by V3 once `setAccountFactory` is set; they need to migrate.
- `isAccount` is written during `initCode` deployment. ERC-7562 treats it as sender-associated storage; if a bundler still rejects it, stake the factory.
- `factory.isAccount(sender)` is a sender-associated read in an external contract, allowed by ERC-7562.

## Signature Validation

`LumiaAccount._validateSignature` recovers the signer directly from the raw `userOpHash` without applying `toEthSignedMessageHash`. This means the frontend must sign the raw `userOpHash` (not via `personal_sign`).

This is safe because the `userOpHash` produced by EntryPoint already includes `chainId`, the EntryPoint address, and the full UserOp structure — providing sufficient replay protection without the Ethereum signed message prefix.

## GasLimitInfo Storage Optimization

The `GasLimitInfo` struct is packed into a single 32-byte storage slot:

| Field | Type | Bytes | Description |
|---|---|---|---|
| `limit` | `uint128` | 16 | Max gas cost in wei (≈ 3.4 × 10³⁸) |
| `lastResetTime` | `uint48` | 6 | Last reset timestamp (until year ~8.9M) |
| `resetPeriod` | `uint48` | 6 | Reset interval in seconds |
| `isResettable` | `bool` | 1 | Whether auto-reset is enabled |
| **Total** | | **29** | Fits in 1 slot |

Previously the struct used 4 storage slots (4 × `uint256`/`bool`). The optimization reduces gas costs for both reads and writes by ~75% for gas limit operations.

## EntryPoint Interface Validation Skip

Both paymasters override `_validateEntryPointInterface` to skip ERC-165 validation. This is necessary because the Lumia Beam EntryPoint deployment may not support `supportsInterface`. The EntryPoint address is still validated as non-zero by the `BasePaymaster` constructor.

## PaymasterCallDataParser

The parser fully ABI-decodes the arguments so that it accepts only calldata that `LumiaAccount` would accept as well. Otherwise the paymaster would sponsor UserOps that are guaranteed to revert inside the account (audit scan 6821846, Low: a 36-byte `execute` with only the target word used to pass). It supports:

- `execute(address,uint256,bytes)` — single target extraction. Calldata shorter than the 3-word head reverts with `InvalidCallData()`; an invalid `bytes` encoding or a target word with dirty upper bits reverts in the ABI decoder.
- `executeBatch(address[],uint256[],bytes[])` — batch target extraction with a 100-element limit. Returns `success = false` unless `dest.length == func.length` and `value.length` is `0` or `func.length` (the checks of `LumiaAccount.executeBatch`).

Unsupported selectors return `success = false`.

## TargetRegistry — Bitmap-Based Many-to-Many

### Overview

Project IDs are derived as `keccak256(name)`. Each project is assigned a sequential **bit index** (0..255) at creation time. Contract-to-project membership and project activity status are tracked via `uint256` bitmaps, enabling O(1) lookups with no loops.

### Storage Layout

| Field | Type | Description |
|---|---|---|
| `nextProjectIndex` | `uint16` | Next available bit index (0..256) |
| `activeProjectsBitmap` | `uint256` | Bit i = project at index i is active |
| `projectBitIndex[id]` | `uint8` | Project ID → bit index |
| `projectExists[id]` | `bool` | Whether a project ID has been registered |
| `contractBitmap[addr]` | `uint256` | Bit i = contract belongs to project at index i |

### Many-to-Many Relationships

A single contract can belong to **multiple projects** simultaneously. For example, if USDT is used by both "Uniswap" (bit 0) and "Aave" (bit 1), then `contractBitmap[USDT] = 0b11 = 3`.

Adding a contract to a project sets the corresponding bit (`|= mask`). Removing clears it (`&= ~mask`). These are O(1) operations.

### Validation in LumiaPaymasterV3

The paymaster stores an `allowedProjectsBitmap` (same structure). Validation for a target is a single bitwise AND:

```
validMask = activeProjectsBitmap & allowedProjectsBitmap   // cached before loop
pass = (contractBitmap[target] & validMask) != 0           // 1 SLOAD per target
```

This replaces the previous approach of 3 external calls per target (`contractToProject` → `allowedProjects` mapping → `isContractInProject`) with 1 external SLOAD per target + 2 cached SLOADs total.

### Empty Batches

When `useProjectAllowlist` is enabled, an `executeBatch` with an empty `dest` array is rejected (`SIG_VALIDATION_FAILED`). Otherwise the target loop would not run and the paymaster would sponsor a UserOp that does nothing, which can be used to burn the deposit. With `useProjectAllowlist` disabled, V3 does not inspect targets and empty batches are accepted (same as V2).

### Changing the Registry

Bit indices are assigned per registry instance, so bit `i` of `allowedProjectsBitmap` points to a different project (or none) in another registry. `setTargetRegistry` therefore clears `allowedProjectsBitmap`. After switching, the owner must re-allow projects with `updateProjectAllowlist` / `batchUpdateProjects`; until then every target is rejected when `useProjectAllowlist` is enabled.

### Limits

- Maximum **256 projects** per registry instance (one `uint256` bitmap).
- Bit indices are **never reused** after project creation to prevent permission inheritance.
- The `isContractInProject` view checks both bitmap membership and `activeProjectsBitmap` status.
