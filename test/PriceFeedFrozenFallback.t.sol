// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

import "../src/PriceFeed.sol";
import "../src/Dependencies/TellorCaller.sol";
import "../src/TestContracts/MockAggregator.sol";
import "../src/TestContracts/MockTellor.sol";
import "../src/SimpleProxy.sol";

// Minimal cheatcode interface (no forge-std: the whole project stays on solc 0.7.6).
interface Vm {
    function warp(uint256) external;

    function expectRevert(bytes calldata) external;
}

// PoC for: once the PriceFeed has switched away from the primary oracle
// (status usingTellorChainlinkUntrusted / bothOraclesUntrusted /
// usingTellorChainlinkFrozen), a frozen-but-valid Tellor fallback blocks any
// return to the primary oracle, even when the primary is healthy again.
// The feed then serves lastGoodPrice until LAST_GOOD_PRICE_TIMEOUT passes,
// after which fetchPrice() reverts and every price-dependent protocol
// function bricks. Uses the live mainnet parameters:
// ORACLE_TIMEOUT = 16 hours, LAST_GOOD_PRICE_TIMEOUT = 2 days.
contract PriceFeedFrozenFallbackTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint constant ORACLE_TIMEOUT = 16 hours;
    uint constant LAST_GOOD_PRICE_TIMEOUT = 2 days;
    uint constant FIL_PRICE = 0.6 ether; // $0.60, 18 decimals
    int constant AGG_PRICE = 60000000; // $0.60, 8 decimals

    MockAggregator agg;
    MockTellor tellor;
    TellorCaller tellorCaller;
    PriceFeed feed;

    function setUp() public {
        vm.warp(1794900000); // realistic "now", 2026-11-17

        agg = new MockAggregator();
        agg.setPrice(AGG_PRICE);
        agg.setUpdateTime(block.timestamp);
        agg.setLatestRoundId(1);

        tellor = new MockTellor();
        tellor.setPrice(FIL_PRICE);
        tellor.setUpdateTime(block.timestamp);

        tellorCaller = new TellorCaller(address(tellor));

        PriceFeed impl = new PriceFeed(ORACLE_TIMEOUT, LAST_GOOD_PRICE_TIMEOUT);
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)",
            address(agg),
            address(tellorCaller)
        );
        SimpleProxy proxy = new SimpleProxy(address(impl), initData);
        feed = PriceFeed(address(proxy));
    }

    // Control: with the primary healthy, a frozen Tellor alone is harmless.
    // The trap needs the status to have switched away from the primary first.
    function testControlPrimaryWorkingWithFrozenTellor() public {
        require(uint8(feed.status()) == 0, "control: not chainlinkWorking");

        vm.warp(block.timestamp + 17 hours);
        agg.setUpdateTime(block.timestamp); // primary fresh
        // Tellor data is now 17h old: frozen, but the feed stays on primary.
        uint p = feed.fetchPrice();
        require(uint8(feed.status()) == 0, "control: status moved");
        require(p == FIL_PRICE, "control: price wrong");

        // LGP keeps refreshing, so no brick even after days.
        vm.warp(block.timestamp + 3 days);
        agg.setUpdateTime(block.timestamp);
        p = feed.fetchPrice();
        require(p == FIL_PRICE, "control: price wrong after 3d");
        require(uint8(feed.status()) == 0, "control: status moved after 3d");
    }

    // Entry via a frozen primary (status 3), then Tellor goes stale too.
    function testState4TrapAndBrick() public {
        uint t0 = block.timestamp;

        // Step 1: primary freezes for 17h, Tellor stays fresh.
        vm.warp(t0 + 17 hours);
        tellor.setUpdateTime(block.timestamp);
        uint p = feed.fetchPrice();
        require(
            uint8(feed.status()) == 3,
            "step1: status not usingTellorChainlinkFrozen"
        );
        require(p == FIL_PRICE, "step1: price not Tellor");
        uint lgpTime = feed.lastGoodPriceTimestamp();
        require(lgpTime == block.timestamp, "step1: LGP timestamp not refreshed");

        // Step 2: primary recovers (fresh, healthy), Tellor goes stale.
        vm.warp(block.timestamp + 17 hours);
        agg.setUpdateTime(block.timestamp);
        // Tellor updateTime still t0 + 17h, now 17h old: frozen.
        p = feed.fetchPrice();
        require(uint8(feed.status()) == 3, "step2: status escaped the trap");
        require(p == feed.lastGoodPrice(), "step2: price is not LGP");

        // Step 3: past LAST_GOOD_PRICE_TIMEOUT, fetchPrice reverts even
        // though the primary oracle is healthy and current.
        vm.warp(lgpTime + LAST_GOOD_PRICE_TIMEOUT + 1);
        agg.setUpdateTime(block.timestamp);
        vm.expectRevert(bytes("PriceFeed: lastGoodPrice is too old"));
        feed.fetchPrice();

        // The non-reverting view still answers, but no core contract uses it.
        uint pv = feed.fetchPriceView();
        require(pv == FIL_PRICE, "step3: view price wrong");

        // The only permissionless escape is a fresh Tellor report.
        tellor.setUpdateTime(block.timestamp);
        tellor.setPrice(FIL_PRICE);
        p = feed.fetchPrice();
        require(uint8(feed.status()) == 0, "recovery: status not chainlinkWorking");
        require(p == FIL_PRICE, "recovery: price wrong");
    }

    // Entry via a broken primary (status 1), then Tellor goes stale too.
    function testState2TrapAndBrick() public {
        uint t0 = block.timestamp;

        // Step 1: primary reverts, Tellor working.
        agg.setLatestRevert();
        uint p = feed.fetchPrice();
        require(
            uint8(feed.status()) == 1,
            "s2 step1: status not usingTellorChainlinkUntrusted"
        );
        require(p == FIL_PRICE, "s2 step1: price not Tellor");
        uint lgpTime = feed.lastGoodPriceTimestamp();

        // Step 2: primary recovers, Tellor goes stale.
        agg.setLatestRevert();
        vm.warp(t0 + 17 hours);
        agg.setUpdateTime(block.timestamp);
        p = feed.fetchPrice();
        require(uint8(feed.status()) == 1, "s2 step2: status escaped the trap");
        require(p == feed.lastGoodPrice(), "s2 step2: price is not LGP");

        // Step 3: past the timeout, fetchPrice reverts with a healthy primary.
        vm.warp(lgpTime + LAST_GOOD_PRICE_TIMEOUT + 1);
        agg.setUpdateTime(block.timestamp);
        vm.expectRevert(bytes("PriceFeed: lastGoodPrice is too old"));
        feed.fetchPrice();
    }

    // Entry via a >50% primary move that Tellor disagrees with (status 2).
    function testState3TrapAndBrick() public {
        uint t0 = block.timestamp;

        // Step 1: primary jumps to $1.21 (+101% vs LGP $0.60), Tellor live
        // at $0.60 and disagreeing by more than 5%.
        agg.setPrice(121000000);
        agg.setUpdateTime(block.timestamp);
        uint p = feed.fetchPrice();
        require(uint8(feed.status()) == 2, "s3 step1: status not bothOraclesUntrusted");
        require(p == FIL_PRICE, "s3 step1: price not LGP");
        uint lgpTime = feed.lastGoodPriceTimestamp(); // still t0, LGP not re-stored

        // Step 2: primary back to $0.60 and fresh, Tellor frozen.
        vm.warp(t0 + 17 hours);
        agg.setPrice(AGG_PRICE);
        agg.setUpdateTime(block.timestamp);
        p = feed.fetchPrice();
        require(uint8(feed.status()) == 2, "s3 step2: status escaped the trap");
        require(p == FIL_PRICE, "s3 step2: price not LGP");

        // Step 3: past the timeout, fetchPrice reverts with a healthy primary.
        vm.warp(lgpTime + LAST_GOOD_PRICE_TIMEOUT + 1);
        agg.setUpdateTime(block.timestamp);
        vm.expectRevert(bytes("PriceFeed: lastGoodPrice is too old"));
        feed.fetchPrice();
    }

    // The owner can unstick the feed by re-setting the oracle addresses
    // (this is the only admin escape; it needs a multisig transaction).
    function testOwnerCanUnstickViaUpdateOracleAddresses() public {
        uint t0 = block.timestamp;
        vm.warp(t0 + 17 hours);
        tellor.setUpdateTime(block.timestamp);
        feed.fetchPrice();
        require(uint8(feed.status()) == 3, "owner: trap not entered");

        vm.warp(block.timestamp + 17 hours);
        agg.setUpdateTime(block.timestamp);
        feed.fetchPrice();
        require(uint8(feed.status()) == 3, "owner: trap escaped on its own");

        feed.updateOracleAddresses(address(agg), address(tellorCaller));
        require(uint8(feed.status()) == 0, "owner: status not reset");
        uint p = feed.fetchPrice();
        require(p == FIL_PRICE, "owner: price wrong after reset");
    }
}
