// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {MultiCurrencyAuction} from "../src/MultiCurrencyAuction.sol";
import {MultiCurrencyAuctionV2} from "../src/MultiCurrencyAuctionV2.sol";
import {TestERC721} from "../src/testContracts/TestERC721.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {console} from "forge-std/console.sol";

contract NftAuctionTest is Test {
    MultiCurrencyAuction public nftAuction;
    MultiCurrencyAuctionV2 public nftAuctionV2;
    TestERC721 public testERC721;
    ERC1967Proxy public proxy;

    address signer = address(1);
    address buyer = address(2);

    function setUp() public {
        // --- 1. 模拟部署逻辑 ---
        vm.startPrank(signer);

        // 部署逻辑合约 (Implementation)
        MultiCurrencyAuction implementation = new MultiCurrencyAuction();

        // 部署代理合约并初始化 (假设 initialize 方法没有参数，根据你实际情况调整)
        proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSelector(MultiCurrencyAuction.initialize.selector)
        );

        // 将 proxy 地址映射为 NftAuction 接口
        nftAuction = MultiCurrencyAuction(address(proxy));

        // 部署 ERC721 并 Mint
        testERC721 = new TestERC721();
        for (uint256 i = 1; i <= 10; i++) {
            testERC721.mint(signer, i);
        }

        // 授权给代理合约
        testERC721.setApprovalForAll(address(proxy), true);

        vm.stopPrank();
    }

    function testUpgrade() public {
        vm.startPrank(signer);

        // --- 2. 创建拍卖 ---
        uint256 duration = 15 minutes;
        //uint256 minPrice = 0.01 ether;
        uint256 tokenId = 1;

        uint256 auctionId = nftAuction.createAuction(
            address(testERC721),
            tokenId,
            0.01 ether,
            block.timestamp + 5 minutes,
            duration
        );

        // 读取拍卖数据
        (, uint256 startTime, , , , , , , , ) = nftAuction.auctions(auctionId);
        console.log("Auction 0 startTime:", startTime);

        // 获取当前逻辑合约地址 (Implementation 1)
        address impl1 = _getImplAddress(address(proxy));
        console.log("Implementation 1:", impl1);

        // --- 3. 升级合约 ---
        MultiCurrencyAuctionV2 implementationV2 = new MultiCurrencyAuctionV2();

        // 调用升级方法
        UUPSUpgradeable(address(proxy)).upgradeToAndCall(
            address(implementationV2),
            ""
        );

        address impl2 = _getImplAddress(address(proxy));
        console.log("Implementation 2:", impl2);

        // --- 4. 验证数据和新功能 ---
        // 验证旧数据是否还在
        (, uint256 startTimeAfter, , , , , , , , ) = nftAuction.auctions(
            auctionId
        );
        assertEq(startTimeAfter, startTime);
        console.log("Auction 0 startTime after upgrade:", startTimeAfter);

        // 验证 V2 的新功能
        nftAuctionV2 = MultiCurrencyAuctionV2(address(proxy));
        string memory hello = nftAuctionV2.testHello();
        console.log("V2 Hello:", hello);
        assertEq(hello, "Hello, World!");

        vm.stopPrank();
    }

    // 辅助函数：获取 ERC1967 代理的逻辑合约地址
    function _getImplAddress(address _proxy) internal view returns (address) {
        // bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)
        // EIP-1967 implementation slot
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        // vm.load 返回 bytes32，直接进行类型转换即可
        return address(uint160(uint256(vm.load(_proxy, slot))));
    }
}
