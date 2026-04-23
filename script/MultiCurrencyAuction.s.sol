// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MultiCurrencyAuction} from "../src/MultiCurrencyAuction.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

contract NFTAuctionScript is Script {
    MultiCurrencyAuction public nftAuction;

    function setUp() public {}

    function run() public {
        // 1. 获取部署者私钥
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // 2. 开启广播
        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署逻辑合约 (Implementation)
        MultiCurrencyAuction implementation = new MultiCurrencyAuction();
        console.log("Implementation deployed at:", address(implementation));

        // 2. 准备初始化数据 (编码调用 initialize 函数)
        bytes memory initData = abi.encodeWithSelector(
            MultiCurrencyAuction.initialize.selector
        );

        // 3. 部署代理合约 (Proxy) 并指向逻辑合约
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );

        // 4. 使用合约接口包装代理地址
        MultiCurrencyAuction auction = MultiCurrencyAuction(address(proxy));

        console.log("Proxy (Auction) deployed at:", address(proxy));
        console.log("Initial Bid Increment Bps:", auction.bidIncrementBps());

        vm.stopBroadcast();
    }
}
