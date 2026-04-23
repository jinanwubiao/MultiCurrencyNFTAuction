// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MultiCurrencyAuction} from "../src/MultiCurrencyAuction.sol";
import {TestERC20} from "../src/testContracts/TestERC20.sol";
import {TestERC721} from "../src/testContracts/TestERC721.sol";
import {MaliciousBidder} from "../src/testContracts/MaliciousBidder.sol";
import {AggreagatorV3} from "../src/testContracts/AggreagatorV3.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {console} from "forge-std/console.sol";

contract MultiCurrencyAuctionTest is Test {
    MultiCurrencyAuction public auctionManager;
    TestERC20 public usdc;
    TestERC721 public nft;
    AggreagatorV3 public ethFeed;
    AggreagatorV3 public usdcFeed;

    address public signer = address(0x1);
    address public buyer = address(0x2);
    address public buyer1 = address(0x3);

    function setUp() public {
        try vm.envUint("TEST_TIME") returns (uint256 t) {
            vm.warp(t);
        } catch {
            vm.warp(1715000000); // 如果没传环境变量,给个当前时间的近似值,否则fountry中的block.timestamp从0开始
        }
        // --- 1. 部署逻辑合约 (Implementation) ---
        MultiCurrencyAuction implementation = new MultiCurrencyAuction();
        console.log("implementation address:", address(implementation));

        // --- 2. 部署代理合约 (Proxy) 并执行初始化 ---
        // 使用 abi.encodeWithSelector 准备初始化函数的调用数据
        bytes memory initData = abi.encodeWithSelector(
            MultiCurrencyAuction.initialize.selector
        );

        // 部署代理，将逻辑合约地址和初始化数据传入
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );

        // --- 3. 将代理地址转回 AuctionManager 类型 ---
        // 之后所有的 auctionManager.xxx 调用都会通过代理指向逻辑合约
        auctionManager = MultiCurrencyAuction(address(proxy));
        console.log("auctionManager proxy address:", address(auctionManager));

        // 4. 部署代币和预言机
        usdc = new TestERC20();
        nft = new TestERC721();

        // 初始价格：ETH = 10000 USD, USDC = 1 USD
        ethFeed = new AggreagatorV3(10000 * 1e18, block.timestamp, 18);
        usdcFeed = new AggreagatorV3(1 * 1e18, block.timestamp, 18);

        // 5. 配置价格喂价 (setPriceFeed)
        auctionManager.setPriceFeed(address(0), address(ethFeed));
        auctionManager.setPriceFeed(address(usdc), address(usdcFeed));

        // 6. 初始化资金和 NFT
        for (uint256 i = 1; i <= 10; i++) {
            nft.mint(signer, i);
        }
        bool success = usdc.transfer(buyer, 1000 * 1e18);
        require(success, "transfer failed");
        vm.deal(buyer1, 10 ether); // 给买家一点 ETH
    }

    function test_AuctionFlow() public {
        console.log("func", "test_AuctionFlow");
        uint256 tokenId = 1;
        uint256 duration = 15 minutes; // 15分钟

        // --- 1. 创建拍卖 ---
        vm.startPrank(signer);
        nft.setApprovalForAll(address(auctionManager), true);
        uint256 auctionId = auctionManager.createAuction(
            address(nft),
            tokenId,
            0.01 ether,
            block.timestamp + 5 minutes,
            duration
        );
        vm.stopPrank();

        // --- 2. ETH 参与竞价 ---
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(buyer1);
        auctionManager.placeBid{value: 0.01 ether}(auctionId, 0, address(0));

        // --- 3. USDC 参与竞价 ---
        console.log(
            "minNextBidUsd",
            auctionManager.getMinNextBidUsd(auctionId)
        );
        vm.startPrank(buyer);
        usdc.approve(address(auctionManager), type(uint256).max);
        // 出价 105 USDC (高于之前的 0.01 ETH，因为 105 > 100)
        auctionManager.placeBid(auctionId, 105 * 1e18, address(usdc));
        vm.stopPrank();

        // --- 4. 结束拍卖 (模拟时间流逝) ---
        // 对应 Hardhat 的 setTimeout(10s)
        vm.warp(block.timestamp + duration + 1);

        vm.prank(signer);
        auctionManager.settleAuction(auctionId);

        // --- 5. 验证结果 ---
        (
            ,
            ,
            ,
            ,
            uint256 highestBid,
            address highestBidder,
            ,
            ,
            ,

        ) = auctionManager.auctions(auctionId);

        assertEq(highestBidder, buyer, "Buyer should be the winner");
        assertEq(highestBid, 105 * 1e18, "Highest bid should be 105 USDC");
        assertEq(
            nft.ownerOf(tokenId),
            buyer,
            "NFT should be transferred to buyer"
        );
        assertEq(usdc.balanceOf(buyer), 895 * 1e18);

        //竞拍失败者取回竞拍金额
        vm.prank(buyer1);
        auctionManager.withdraw(address(0));
        assertEq(address(buyer1).balance, 10 ether);
    }

    function test_Attack_AsyncRefundPreventsLock() public {
        uint256 tokenId = 2;
        uint256 minPriceUsd = 100 * 1e18; // 100 USD

        // 1. 发起拍卖
        vm.startPrank(signer);
        nft.setApprovalForAll(address(auctionManager), true);
        uint256 auctionId = auctionManager.createAuction(
            address(nft),
            tokenId,
            minPriceUsd,
            block.timestamp,
            15 minutes
        );
        vm.stopPrank();

        // 2. 恶意合约出价 (0.02 ETH = 200 USD)
        MaliciousBidder attacker = new MaliciousBidder();
        vm.deal(address(attacker), 1 ether);
        attacker.bid(address(auctionManager), auctionId, 0.02 ether);

        // 验证：目前最高出价者是恶意合约
        (, , , , , address highestBidder, , , , ) = auctionManager.auctions(
            auctionId
        );
        assertEq(highestBidder, address(attacker));

        // 3. 正常买家尝试超越出价 (0.03 ETH = 300 USD)
        vm.deal(buyer, 1 ether);
        vm.prank(buyer); // 如果合约里用的是直接转账给上一个人的逻辑，这里会 revert，因为 attacker 拒绝接收
        auctionManager.placeBid{value: 0.03 ether}(auctionId, 0, address(0));

        // 4. 验证结果：正常买家成功成为最高出价者
        (, , , , , address newHighestBidder, , , , ) = auctionManager.auctions(
            auctionId
        );
        assertEq(
            newHighestBidder,
            buyer,
            "Auction should continue despite malicious bidder"
        );

        // 5. 验证：恶意合约的钱被“锁”在 pendingBalances 里面，但他无法提走
        uint256 stuckBalance = auctionManager.userPendingBalances(
            address(attacker),
            address(0)
        );
        assertEq(
            stuckBalance,
            0.02 ether,
            "Malicious bidder's funds should be safely held in contract"
        );

        // 恶意合约尝试提款会失败 (因为它 receive() 会 revert)
        vm.prank(address(attacker));
        vm.expectRevert(); // 预期会失败
        auctionManager.withdraw(address(0));
    }

    function test_Cancel_Auction() public {
        uint256 tokenId = 3;
        uint256 minPriceUsd = 100 * 1e18; // 100 USD

        // 1. 发起拍卖
        vm.startPrank(signer);
        nft.setApprovalForAll(address(auctionManager), true);
        uint256 currentTime = block.timestamp;
        uint256 auctionId = auctionManager.createAuction(
            address(nft),
            tokenId,
            minPriceUsd,
            currentTime + 30 minutes,
            15 minutes
        );
        vm.stopPrank();

        vm.warp(currentTime + 5 minutes);
        vm.prank(buyer1);
        vm.expectRevert(); //未到拍卖时间,竞拍失败
        auctionManager.placeBid{value: 0.01 ether}(auctionId, 0, address(0));

        vm.warp(currentTime + 29 minutes);
        vm.prank(signer);
        auctionManager.cancelAuction(auctionId);
        //验证是否正常取消
        (address seller, , , , , , , , , ) = auctionManager.auctions(auctionId);
        assertEq(seller, address(0));
        assertNotEq(
            auctionManager.nftToActiveAuctionId(address(nft), tokenId),
            auctionId
        );
    }
}
