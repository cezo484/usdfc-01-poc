# PoC: USDFC-01 — frozen Tellor fallback traps PriceFeed

Foundry project, solc 0.7.6, no external dependencies (no forge-std).
The test uses the real `PriceFeed.sol` and `TellorCaller.sol` copied
verbatim from the USDFC repo (HEAD ea5e205), deployed behind a minimal
EIP-1967 proxy the same way they are deployed on mainnet, with the
repo's own `MockAggregator` and `MockTellor` as oracles, at the live
mainnet parameters (ORACLE_TIMEOUT 16h, LAST_GOOD_PRICE_TIMEOUT 2d).

## Run

```
forge test
```

Expected: 5 passed, 0 failed.

## Tests

| Test | What it proves |
|---|---|
| testControlPrimaryWorkingWithFrozenTellor | With the primary healthy, a frozen Tellor alone is harmless (status stays chainlinkWorking). The trap needs the status to have switched first. |
| testState4TrapAndBrick | Primary freezes 17h (status 3), Tellor then goes stale, primary recovers healthy: status stays 3 serving lastGoodPrice; after 2 days fetchPrice() reverts with "PriceFeed: lastGoodPrice is too old". A fresh Tellor report is the only permissionless escape. |
| testState2TrapAndBrick | Same trap through status 1 (primary broke, then recovered). |
| testState3TrapAndBrick | Same trap through status 2 (primary moved >50%, Tellor disagreed). |
| testOwnerCanUnstickViaUpdateOracleAddresses | The owner can reset the status with updateOracleAddresses() (multisig tx). |

## Layout

- `src/` — verbatim repo contracts (PriceFeed, TellorCaller,
  dependencies, interfaces, MockAggregator, MockTellor) + SimpleProxy
  (minimal EIP-1967 proxy written for this PoC).
- `test/PriceFeedFrozenFallback.t.sol` — the 5 tests.
- `foundry.toml` — solc 0.7.6, evm_version istanbul.

PoC for the USDFC-01 report.
