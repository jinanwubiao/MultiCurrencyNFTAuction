// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiCurrencyAuction} from "../src/MultiCurrencyAuction.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AggreagatorV3} from "../src/testContracts/AggreagatorV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// 简单的 Mock 代币用于测试不同 Decimals
contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 dec
    ) ERC20(name, symbol) {
        _decimals = dec;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract AuctionPriceTest is Test {
    MultiCurrencyAuction public auction;
    AggreagatorV3 public ethPriceFeed;
    AggreagatorV3 public usdcPriceFeed;
    MockERC20 public usdc;

    function setUp() public {
        try vm.envUint("TEST_TIME") returns (uint256 t) {
            vm.warp(t);
        } catch {
            vm.warp(1715000000); // 如果没传环境变量,给个当前时间的近似值,否则fountry中的block.timestamp从0开始
        }
        // 1. 部署逻辑合约
        MultiCurrencyAuction implementation = new MultiCurrencyAuction();

        // 2. 部署代理并初始化
        bytes memory initData = abi.encodeWithSelector(
            MultiCurrencyAuction.initialize.selector
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );
        auction = MultiCurrencyAuction(address(proxy));

        // 3. 部署 Mock 预言机 (模拟 Chainlink)
        // 假设 ETH 价格为 $3000 (8位精度: 3000 * 10^8)
        ethPriceFeed = new AggreagatorV3(3000 * 1e18, block.timestamp, 18);
        // 假设 USDC 价格为 $1 (8位精度: 1 * 10^8)
        usdcPriceFeed = new AggreagatorV3(1 * 1e8, block.timestamp, 8);

        // 4. 部署 Mock 代币 (USDC 通常是 6位)
        usdc = new MockERC20("USDC", "USDC", 6);

        // 5. 配置合约中的 PriceFeed
        auction.setPriceFeed(address(0), address(ethPriceFeed)); // ETH
        auction.setPriceFeed(address(usdc), address(usdcPriceFeed)); // USDC
    }

    function test_GetUsdValue_ETH() public view {
        // 输入：1个 ETH (1e18)
        // 预期：$3000，且返回值应缩放到 1e18 精度
        uint256 amount = 1 ether;
        uint256 usdValue = auction.getUsdValue(address(0), amount);

        // 合约逻辑：(1e18 * 3000e18 * 1e18) / (10^18 * 10^18) = 3000e18
        assertEq(usdValue, 3000 * 1e18);
    }

    function test_GetUsdValue_USDC() public view {
        // 输入：100个 USDC (100 * 10^6)
        // 预期：$100，返回值缩放至 1e18
        uint256 amount = 100 * 1e6;
        uint256 usdValue = auction.getUsdValue(address(usdc), amount);

        // 合约逻辑：(100e6 * 1e8 * 1e18) / (10^6 * 10^8) = 100e18
        assertEq(usdValue, 100 * 1e18);
    }

    function test_RevertWhen_PriceStale() public {
        // 模拟时间流逝，超过合约定义的 25小时 (STALE_PRICE_DELAY)
        vm.warp(block.timestamp + 26 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                MultiCurrencyAuction.OraclePriceStale.selector,
                address(0)
            )
        );
        auction.getUsdValue(address(0), 1 ether);
    }
}
