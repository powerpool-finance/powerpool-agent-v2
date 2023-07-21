# PowerPool Agent V2

Decentralized network for guaranteed, automatic, gasless transactions execution and off-chain computations for Defi/Web3 apps and individuals.

The main purpose of PowerAgent is to execute (call) smart contracts based on the specific logic of the Task, submitted to the network.

The execution logic can contain on-chain conditions and, in the future, off-chain data and computation results.

## How to run tests

* Clone the repo `git clone  --recurse-submodules https://github.com/powerpool-finance/powerpool-agent-v2.git`
* Set up foundry https://github.com/foundry-rs/foundry#installation. At the moment the following instructions are valid:
  * `curl -L https://foundry.paradigm.xyz | bash`
  * Reload your PATH env var, for ex. by restarting a terminal session
  * `foundryup`
* Run all the tests:
```shell
forge test -vvv
```
* Run a particular test (verbose details only if a test fails, 3-v):
```shell
forge test -vvv -m testSetAgentParams
```
* Print verbose debug info for a test (4-v):
```shell
forge test -vvvv -m testSetAgentParams
```
* Re-compile all contracts with sizes output:
```shell
forge build --sizes --force
```
