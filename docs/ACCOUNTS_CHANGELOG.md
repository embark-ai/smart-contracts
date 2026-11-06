# Accounts Changelog: LumiaAccount and LumiaAccountFactory

Changes to the smart account and its factory, by account version (`LumiaAccount.version()`).

| Version | Commit | Date | Summary |
|---|---|---|---|
| **3.0.0** | _(this branch)_ | 2026-11-07 | ERC-1271 + `executeFromExecutor` for MetaMask Delegation Framework (ERC-7710) |
| **2.0.0** | `035164f` | 2026-10-27 | Factory-bound accounts: account registry, upgrades restricted to factory-approved implementations |
| **1.0.0** | `a263906` | 2025-08-20 | eth-infinitism `SimpleAccount` pattern, UUPS, CREATE2 factory |

---

## v3.0.0 — Delegation Framework (ERC-7710)

Extends the same `LumiaAccount` for MetaMask `DelegationManager` redeem. No separate account type.

### LumiaAccount

| | v2.0.0 | v3.0.0 |
|---|---|---|
| Constructor | `(entryPoint, factory)` | `(entryPoint, factory, delegationManager)` |
| `delegationManager()` | — | immutable; only this address may call `executeFromExecutor` |
| ERC-1271 | — | `isValidSignature(hash, signature)` — raw hash, owner ECDSA |
| Executor entry | — | `executeFromExecutor(mode, executionCalldata)` — ERC-7579 single/batch, `EXECTYPE_DEFAULT` only |
| `version()` | `"2.0.0"` | `"3.0.0"` |

Storage layout unchanged (`delegationManager` is immutable on the implementation). Owner/`execute`/`validateUserOp` semantics unchanged.

Pulsar/Lark testnet DM (verified MetaMask DF `1.3.0`): `0xd2B20CDB5aFdf06d54797a032505F4E025FF99d3`.

### LumiaAccountFactory

Constructor is now `constructor(IEntryPoint, address delegationManager)`. The live Pulsar factory still has an immutable v2 implementation, so **new CREATE2 accounts with v3 need a newly deployed factory** (or upgrade existing proxies to a v3 impl approved on the legacy factory).

---

## v2.0.0 — factory-bound accounts

Fix for the audit scan 6821846 finding "Project allowlist does not bind parsed targets to the sender account's execution" (Low). `LumiaPaymasterV3` derives call targets from `userOp.callData`, but the code of `userOp.sender` decides what is executed. A selector-compatible custom account, or a `LumiaAccount` upgraded to arbitrary code, could pass the project allowlist while running other logic paid by the paymaster. v2 lets the paymaster trust that a sender runs Lumia code. Details: `docs/IMPLEMENTATION_NOTES.md` ("Account Registry and Restricted Upgrades").

### LumiaAccount

| | v1.0.0 | v2.0.0 |
|---|---|---|
| Constructor | `constructor(IEntryPoint entryPoint)` | `constructor(IEntryPoint entryPoint, ILumiaAccountFactory factory)` |
| Factory reference | — | `factory()` — immutable, the factory that deployed the implementation |
| `_authorizeUpgrade` | owner or self only | owner or self **and** `factory.isApprovedImplementation(newImpl)` |
| New error | — | `UnapprovedImplementation(address implementation)` |
| `version()` | `"1.0.0"` | `"2.0.0"` |

Unchanged: storage layout, `initialize(owner)`, `execute`, `executeBatch`, signature validation (raw `userOpHash`, no `personal_sign` prefix), deposit helpers, ERC721/ERC1155 callbacks, `LumiaAccountInitialized` event.

Storage layout (identical in both versions, verified with `forge inspect ... storageLayout`):

| Slot | Offset | Variable |
|---|---|---|
| 0 | 0 | `_initialized` (`uint8`) |
| 0 | 1 | `_initializing` (`bool`) |
| 0 | 2 | `owner` (`address`) |

### LumiaAccountFactory

| | v1 | v2 |
|---|---|---|
| Ownership | none | `Ownable`, the deployer becomes owner |
| Account registry | — | `isAccount(address) → bool`, set in `createAccount` |
| Upgrade targets | — | `isApprovedImplementation(address) → bool`; the base implementation is approved in the constructor |
| Admin function | — | `setImplementationApproval(address impl, bool approved)` (`onlyOwner`, reverts with `ImplementationHasNoCode` when approving an address without code) |
| New event | — | `ImplementationApprovalUpdated(address indexed implementation, bool approved)` |

Unchanged: `constructor(IEntryPoint)`, `createAccount(owner, salt)`, `getAddress(owner, salt)`, `implementation()`, `accountImplementation`, `entryPoint`, `AccountCreated` event, idempotent `createAccount`.

### Related paymaster change

`LumiaPaymasterV3.setAccountFactory(address factory)` (`onlyOwner`). When set, validation fails (`SIG_VALIDATION_FAILED`) for senders where `factory.isAccount(sender)` is false. `address(0)` disables the check. New accounts deployed through `initCode` pass, because `isAccount` is written before paymaster validation.

### Breaking changes

- **New account addresses.** The implementation constructor changed, so the implementation address and every counterfactual `getAddress(owner, salt)` of a v2 factory differ from v1. The same `(owner, salt)` produces a different account address.
- **v1 accounts are not registered** in a v2 factory. `LumiaPaymasterV3` with `setAccountFactory` rejects them. This affects testnets only: v1 user accounts never existed on mainnet.
- **Integrations** must point the SDK / backend to the v2 factory address. The factory ABI for account creation is unchanged.
- **Verification**: the implementation is verified with `constructor(address,address)` args (`entryPoint`, `factory`) instead of `constructor(address)`.

### Trust assumptions introduced

- The factory owner is trusted: every approved implementation **must** keep the factory-restricted `_authorizeUpgrade`, otherwise a registered account could upgrade to arbitrary code.
- Revoking an implementation (`approved = false`) only blocks future upgrades; accounts already running it are not affected.
- An owner signature can still upgrade an account, but only to an approved implementation (see `docs/AUDIT.md`, "Account upgrade via self-call").

### Migrating v1 accounts

**Mainnet:** no migration is needed. v1 user accounts existed only on testnets; on mainnet users create new v2 accounts through the v2 factory. The deprecated v1 mainnet factory was never used for user accounts.

**Testnets:** existing v1 accounts can either move funds to a new v2 account (recommended; the new account is registered and sponsored by V3 with `setAccountFactory`), or upgrade in place with `execute(account, 0, upgradeToAndCall(v2Implementation, ""))`. The storage layout is identical, so the address and assets are kept, but an upgraded v1 account is still **not** in `isAccount` of the v2 factory and V3 with `setAccountFactory` keeps rejecting it.

### Tests

- `test/LumiaAccount.t.sol`: `testFactoryRegistersCreatedAccounts`, `testBaseImplementationApprovedAndFactoryOwned`, `testUpgradeToUnapprovedImplementationReverts`, `testUpgradeToApprovedImplementation`, `testUpgradeRevokedImplementationReverts`, `testUpgradeByNonOwnerReverts`, `testSetImplementationApprovalOnlyOwner`, `testSetImplementationApprovalRequiresCode`, `testSetImplementationApprovalEmitsEvent`.
- `test/AuditFixes.t.sol` (end-to-end through EntryPoint v0.7): `testLow_SelectorCompatibleAccountSponsoredWithoutFactoryCheck`, `testLow_SelectorCompatibleAccountRejectedWithFactoryCheck`, `testLow_FactoryAccountSponsoredWithFactoryCheck`, `testLow_NewAccountViaInitCodeSponsoredWithFactoryCheck`, `testLow_FactoryAccountCannotUpgradeToRogueImplementation`.

### Deployments

| Chain | Version | Factory | Implementation |
|---|---|---|---|
| BSC Mainnet (56) | v2.0.0 | `0x17444C55ebFD850d171d046Ce08F7fbc3859497b` | `0xCd2d8c054904287f47f2612a0aDaF6cc4d12D7AB` |
| BSC Mainnet (56), deprecated, no user accounts | v1.0.0 | `0x536b6F1Db43AA3D537376E40f73cFdcFf8930244` | `0x7e2faDB88646C1208095d56FEFe54F7E70f5dcb7` |

Details: [DEPLOYMENT_BSC_MAINNET.md](../DEPLOYMENT_BSC_MAINNET.md).

---

## v1.0.0 — SimpleAccount pattern

Initial account built on eth-infinitism `BaseAccount` (EntryPoint v0.7), replacing the earlier Solady-based implementation.

- Single ECDSA owner; signature over the raw `userOpHash`.
- `execute` / `executeBatch` callable by EntryPoint or owner.
- UUPS upgrades authorized by the owner or by the account itself (via `execute`).
- ERC721 / ERC1155 token callbacks, EntryPoint deposit helpers.
- `LumiaAccountFactory`: CREATE2 deployment of `ERC1967Proxy` with `initialize(owner)`, `createAccount(owner, salt)`, `getAddress(owner, salt)`; returns the existing account if already deployed.
- Compiler pinned to `=0.8.28` (commit `81e3be5`); events moved to `src/interfaces/` (commit `13975bb`) without changing behavior.
