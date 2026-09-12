// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {MarketState} from "../../src/IMarketStateAdapter.sol";
import {AggregatorV3Interface} from "../../src/AggregatorV3Interface.sol";
import {ChainlinkEquityAdapter} from "../../src/ChainlinkEquityAdapter.sol";

/// Reads the real Chainlink feeds on Robinhood Chain (ID 4663) through the adapter.
/// Run with:  forge test --match-path test/fork/Adapter.fork.t.sol --fork-url $ROBINHOOD_RPC -vv
/// Skipped when no fork is active so the unit suite stays fast.
contract AdapterForkTest is Test {
    // docs/verified-onchain.md
    address constant AAPL_USD = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant SPY_USD = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address constant USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant AAPL_TOKEN = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    uint256 constant MAX_STALENESS = 3 days; // covers the ~52h weekend gap
    uint256 constant PLAUSIBILITY_BPS = 2000; // 20% jump between prints is implausible

    function setUp() public {
        if (block.chainid != 4663) vm.skip(true);
    }

    function test_aaplFeed_readsThroughAdapter() public {
        ChainlinkEquityAdapter a = new ChainlinkEquityAdapter(AAPL_USD, address(0), AAPL_TOKEN, MAX_STALENESS, PLAUSIBILITY_BPS);
        MarketState memory m = a.getMarketState();
        _log("AAPL/USD", m);

        (, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(AAPL_USD).latestRoundData();
        assertEq(m.price, uint256(answer) * 1e10, "8-decimal answer scaled to 1e18");
        assertGt(m.price, 50e18, "AAPL above $50");
        assertLt(m.price, 2000e18, "AAPL below $2000");
        assertLe(m.loPrice, m.price, "window low <= price");
        assertGe(m.hiPrice, m.price, "window high >= price");
        assertEq(m.isLive, block.timestamp - updatedAt <= MAX_STALENESS, "isLive matches staleness");
        assertFalse(m.hasQuoteFeed, "dollar-quoted: no quote feed");
    }

    function test_aaplOverUsdg_readsThroughAdapter() public {
        ChainlinkEquityAdapter a = new ChainlinkEquityAdapter(AAPL_USD, USDG_USD, AAPL_TOKEN, MAX_STALENESS, PLAUSIBILITY_BPS);
        MarketState memory m = a.getMarketState();
        _log("AAPL/USD over USDG/USD", m);

        assertTrue(m.hasQuoteFeed, "quote feed present");
        assertApproxEqRel(m.quotePrice, 1e18, 0.02e18, "USDG within 2% of $1");
        assertLe(m.loQuotePrice, m.quotePrice, "quote window low <= quote");
        assertGe(m.hiQuotePrice, m.quotePrice, "quote window high >= quote");
    }

    function test_spyFeed_readsThroughAdapter() public {
        ChainlinkEquityAdapter a = new ChainlinkEquityAdapter(SPY_USD, address(0), address(0), MAX_STALENESS, PLAUSIBILITY_BPS);
        MarketState memory m = a.getMarketState();
        _log("SPY/USD", m);
        assertGt(m.price, 200e18, "SPY above $200");
    }

    function _log(string memory name, MarketState memory m) internal view {
        console2.log("---", name, "at block", block.number);
        console2.log("  isLive       ", m.isLive);
        console2.log("  price        ", m.price);
        console2.log("  loPrice      ", m.loPrice);
        console2.log("  hiPrice      ", m.hiPrice);
        console2.log("  hasQuoteFeed ", m.hasQuoteFeed);
        console2.log("  quotePrice   ", m.quotePrice);
        console2.log("  loQuotePrice ", m.loQuotePrice);
        console2.log("  hiQuotePrice ", m.hiQuotePrice);
    }
}
