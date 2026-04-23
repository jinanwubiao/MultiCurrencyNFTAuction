// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract AggreagatorV3 is AggregatorV3Interface {
    uint8 public decimals;
    uint256 public updatedAt;
    int256 answer;

    constructor(int256 _answer, uint256 _updatedAt, uint8 _decimals) {
        answer = _answer;
        updatedAt = _updatedAt;
        decimals = _decimals;
    }

    function description() external pure returns (string memory) {
        return "a test price feeder";
    }

    function version() external pure returns (uint256) {
        return 0;
    }

    function getRoundData(
        uint80
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, updatedAt, updatedAt, 0);
    }

    function latestRoundData()
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, answer, updatedAt, updatedAt, 0);
    }

    function setPrice(int256 _answer) public {
        answer = _answer;
    }
}
