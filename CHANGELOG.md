# PPAgentV2 Changelog

### 2.4.0

- Added job key to execute calldata.

### 2.3.0

- Reworked interfaces and inheritance.

### 2.2.0

- Fix "execute + job update" reentrancy bug.

### 2.1.0

- Remove ERC20 functionality.
- Add `keeperWorker => keeperId` mapping. Now a keeperWorker can be assigned to only one keeper. The first keeperId
  now is 1 instead of 0.
- Make the first jobId for an address to be 1 to make its behaviour similar to keeperId.
- Bump Solidity compiler to v0.8.15.
- Add RegisterJob event jobID argument.

### 2.0.0

- The initial release.
