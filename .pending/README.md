Parked tests: they reference contracts not yet written, and Forge compiles the whole
project before running any test. Move each back as you finish the contract it grades.

  after src/AggregatorV3Interface.sol + src/ChainlinkEquityAdapter.sol:
      mv .pending/MockAggregatorV3.sol test/mocks/
      mv .pending/ChainlinkEquityAdapter.t.sol test/

  after src/ClosingBellHook.sol:
      mv .pending/ClosingBellHook.t.sol test/

  after both:
      mv .pending/EndToEnd.t.sol test/
