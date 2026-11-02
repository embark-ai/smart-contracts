# Nonce Management in the Lumia Account Abstraction System

## Nonce system overview

In the Account Abstraction (AA) system, nonce is used for replay protection, as in regular Ethereum transactions. The AA nonce system is more flexible and powerful, however.

## Nonce structure

The AA nonce consists of two parts:
1. **Key (192 bits)** — high bits
2. **Sequence (64 bits)** — low bits

Format: `nonce = (key << 64) | sequence`

## How the nonce system works

### 1. Getting the current nonce
Each account can get its next nonce via the EntryPoint:
```solidity
function getNonce(address sender, uint192 key) public view returns (uint256 nonce)
```

In `LumiaAccount.sol` the method to get nonce is:
```solidity
function getNonce() public view virtual returns (uint256) {
    return entryPoint().getNonce(address(this), 0);
}
```

### 2. Sequence management
The `NonceManager.sol` contract manages the nonce sequence per account and key:
```solidity
mapping(address => mapping(uint192 => uint256)) public nonceSequenceNumber;
```

### 3. Validation and nonce update
When processing a UserOperation, the EntryPoint validates and updates the nonce:
```solidity
function _validateAndUpdateNonce(address sender, uint256 nonce) internal returns (bool) {
    uint192 key = uint192(nonce >> 64);
    uint64 seq = uint64(nonce);
    return nonceSequenceNumber[sender][key]++ == seq;
}
```

## Lumia implementation details

### 1. Key flexibility
The system supports different keys for parallel transaction processing:
- Key 0: Sequential transactions (default)
- Other keys: Parallel transactions

### 2. Automatic management
The EntryPoint updates the nonce automatically after successful validation, so accounts do not need to increment nonce manually.

### 3. Account check
The `BaseAccount.sol` contract calls `_validateNonce()` during UserOperation validation; by default this method is empty because validation is done in the EntryPoint.

## Benefits

1. **Parallelism**: Different keys allow parallel execution of transactions
2. **Flexibility**: Complex nonce management scenarios are possible
3. **Security**: Automatic nonce uniqueness checks
4. **Gas efficiency**: Option to “pre-increment” nonce to spread gas cost

## Usage recommendations

1. Use key 0 for sequential transactions (standard case)
2. Use other keys for parallel operations
3. Do not manage nonce manually in the account — that is the EntryPoint’s job
4. When creating an account, you can call `incrementNonce()` to optimize gas on the first transaction
