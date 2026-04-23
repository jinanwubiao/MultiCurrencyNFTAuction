// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

//import {console} from "forge-std/console.sol";

/**
 *
 * @title 多币种 NFT 拍卖合约 (UUPS 可升级)
 * @notice 支持ETH和ERC20竞价,通过chainlink实现USD价值对齐
 * **/
contract MultiCurrencyAuction is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardTransient
{
    struct Auction {
        address seller; //买家地址
        uint256 startTime; //起拍时间
        uint256 duration; //拍卖持续时间
        uint256 minUsdValue; //起拍价格
        uint256 highestBid; //最高出价的原始代币数量
        address highestBidder; //最高出价者
        address nftContract; //nft合约地址
        uint256 tokenId; //nft tokenId
        address bidToken; //代币付款地址,address(0)代表ETH付款,其他地址代表ERC20付款
        bool isEnded; //是否结束
    }

    uint256 public constant MIN_DURATION = 15 minutes;
    uint256 public constant MAX_DURATION = 30 days;
    uint256 public constant BPS_DENOMINATOR = 10000; // 万分位分母
    uint256 public constant STALE_PRICE_DELAY = 25 hours; // 预言机过期阈值

    uint256 public auctionIdCounter; //拍卖全局计数器
    uint256 public bidIncrementBps; //最小加价幅度 (如 500 代表 5%)

    mapping(uint256 => Auction) public auctions;
    mapping(address => mapping(uint256 => uint256)) public nftToActiveAuctionId;
    mapping(address => AggregatorV3Interface) public priceFeeds;

    // 异步退款：用户 => 代币 => 余额
    mapping(address => mapping(address => uint256)) public userPendingBalances;

    // --- 自定义错误 ---
    error NotSeller(); // 只有卖家能操作
    error AuctionNotFound(); // 拍卖 ID 不存在
    error AuctionAlreadyStarted(uint256 startTime); // 已经开始，无法取消
    error AuctionNotStarted(uint256 startTime); // 还没开始，无法出价
    error AuctionActive(); // 正在进行中，无法结算
    error AuctionFinished(); // 已经结束，无法操作
    error AuctionAlreadyExists(uint256 auctionId); // NFT 已在另一场拍卖中
    error InvalidPayment(); // 支付金额为 0
    error InvalidStartBidPrice(); // 起拍金额为0
    error BidTooLow(uint256 requiredUsd, uint256 actualUsd); // 出价未达门槛
    error OracleNotConfigured(address token); // 未配置报价源
    error OraclePriceStale(address token); // 预言机数据过期
    error InvalidPriceFeed(address feed); // 无效的预言机地址
    error TransferFailed(); // 资金转移失败
    error InvalidAddress(); // 零地址错误
    error InvalidDuration(); // 持续时间不合规
    error StartTimeTooFar(uint256 maxStartTime); // 拍卖开始时间设置太大
    error MixedPaymentDisabled(); // 禁用混合出价

    // --- 事件 ---
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint256 minUsdValue,
        uint256 startTime,
        uint256 endTime
    );
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        address token,
        uint256 rawAmount,
        uint256 usdAmount
    );
    event AuctionCancelled(uint256 indexed auctionId);
    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed winner,
        uint256 amount,
        address token
    );
    event FundsWithdrawn(address indexed user, address token, uint256 amount);

    // 禁用constructor
    constructor() {
        _disableInitializers();
    }

    // 初始化
    function initialize() public initializer {
        __Ownable_init(msg.sender);
        bidIncrementBps = 500; // 默认 5%
    }

    // UUPS升级
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice 配置或更新代币的 Chainlink 报价源
     */
    function setPriceFeed(address token, address feed) external onlyOwner {
        if (feed == address(0)) revert InvalidAddress();

        try AggregatorV3Interface(feed).decimals() returns (uint8) {
            priceFeeds[token] = AggregatorV3Interface(feed);
        } catch {
            revert InvalidPriceFeed(feed);
        }
    }

    /**
     * @notice 设置/更新最小加价幅度
     */
    function setBidIncrementBps(uint256 _bidIncrementBps) external onlyOwner {
        bidIncrementBps = _bidIncrementBps;
    }

    /**
     * @notice 计算USD价值
     */
    function getUsdValue(
        address _token,
        uint256 _amount
    ) public view returns (uint256) {
        AggregatorV3Interface feed = priceFeeds[_token];
        if (address(feed) == address(0)) revert OracleNotConfigured(_token);

        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();
        if (price <= 0) revert InvalidPriceFeed(address(feed));
        if (block.timestamp - updatedAt > STALE_PRICE_DELAY)
            revert OraclePriceStale(_token);

        uint256 tDec = (_token == address(0))
            ? 18
            : uint256(IERC20Metadata(_token).decimals());
        uint256 oDec = uint256(feed.decimals());
        // forge-lint: disable-next-line(unsafe-typecast)
        return (_amount * uint256(price) * 1e18) / (10 ** tDec * 10 ** oDec);
    }

    /**
     * @notice 发起新拍卖
     */
    function createAuction(
        address _nftContract,
        uint256 _tokenId,
        uint256 _minUsdValue,
        uint256 _startTime,
        uint256 _duration
    ) external returns (uint256) {
        // 1. 基础校验
        if (_minUsdValue == 0) revert InvalidStartBidPrice();
        if (_duration < MIN_DURATION || _duration > MAX_DURATION)
            revert InvalidDuration();

        // 2. 时间校验
        uint256 actualStartTime = _startTime;
        if (_startTime < block.timestamp) {
            actualStartTime = block.timestamp; //立即开始
        }
        if (actualStartTime > block.timestamp + 30 days)
            revert StartTimeTooFar(block.timestamp + 30 days);

        // 3. nft是否正在拍卖
        uint256 activeId = nftToActiveAuctionId[_nftContract][_tokenId];
        if (activeId != 0) revert AuctionAlreadyExists(activeId);

        // 4. 锁定NFT
        IERC721(_nftContract).transferFrom(msg.sender, address(this), _tokenId);

        uint256 newAuctionId = ++auctionIdCounter;
        auctions[newAuctionId] = Auction({
            seller: msg.sender,
            startTime: actualStartTime,
            duration: _duration,
            minUsdValue: _minUsdValue,
            highestBid: 0,
            highestBidder: address(0),
            nftContract: _nftContract,
            tokenId: _tokenId,
            bidToken: address(0),
            isEnded: false
        });

        nftToActiveAuctionId[_nftContract][_tokenId] = newAuctionId;
        emit AuctionCreated(
            newAuctionId,
            msg.sender,
            _nftContract,
            _tokenId,
            _minUsdValue,
            actualStartTime,
            actualStartTime + _duration
        );
        return newAuctionId;
    }

    /**
     * @notice 竞拍
     */
    function placeBid(
        uint256 _auctionId,
        uint256 _amount,
        address _tokenAddress
    ) external payable nonReentrant {
        Auction storage auction = auctions[_auctionId];

        if (auction.seller == address(0)) revert AuctionNotFound();
        if (block.timestamp < auction.startTime)
            revert AuctionNotStarted(auction.startTime);
        if (
            auction.isEnded ||
            block.timestamp >= auction.startTime + auction.duration
        ) revert AuctionFinished();

        if (msg.value > 0) {
            if (_tokenAddress != address(0) || _amount > 0)
                revert MixedPaymentDisabled();
        }

        address currentToken = (msg.value > 0) ? address(0) : _tokenAddress;
        uint256 rawAmount = (msg.value > 0) ? msg.value : _amount;
        if (rawAmount == 0) revert InvalidPayment();

        uint256 currentBidUsd = getUsdValue(currentToken, rawAmount);

        if (auction.highestBid > 0) {
            //已有出价者
            uint256 highestBidUsd = getUsdValue(
                auction.bidToken,
                auction.highestBid
            );
            uint256 minRequiredUsd = (highestBidUsd *
                (BPS_DENOMINATOR + bidIncrementBps)) / BPS_DENOMINATOR;
            if (currentBidUsd < minRequiredUsd)
                revert BidTooLow(minRequiredUsd, currentBidUsd);
            //记录退款金额,不直接转账。防止转入恶意合约导致锁死拍卖
            userPendingBalances[auction.highestBidder][
                auction.bidToken
            ] += auction.highestBid;
        } else {
            //第一次竞拍,出价不能小于地板价
            if (currentBidUsd < auction.minUsdValue)
                revert BidTooLow(auction.minUsdValue, currentBidUsd);
        }

        if (currentToken != address(0)) {
            bool success = IERC20(currentToken).transferFrom(
                msg.sender,
                address(this),
                rawAmount
            );
            if (!success) revert TransferFailed();
        }

        auction.highestBid = rawAmount;
        auction.highestBidder = msg.sender;
        auction.bidToken = currentToken;

        emit BidPlaced(
            _auctionId,
            msg.sender,
            currentToken,
            rawAmount,
            currentBidUsd
        );
    }

    /**
     * @notice 取消竞拍
     */
    function cancelAuction(uint256 _auctionId) external {
        Auction storage auction = auctions[_auctionId];
        if (msg.sender != auction.seller) revert NotSeller();
        if (block.timestamp >= auction.startTime)
            revert AuctionAlreadyStarted(auction.startTime);

        nftToActiveAuctionId[auction.nftContract][auction.tokenId] = 0;
        IERC721(auction.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            auction.tokenId
        );

        delete auctions[_auctionId];
        emit AuctionCancelled(_auctionId);
    }

    /**
     * @notice 结束竞拍
     */
    function settleAuction(uint256 _auctionId) external nonReentrant {
        Auction storage auction = auctions[_auctionId];
        if (auction.isEnded) revert AuctionFinished();
        if (block.timestamp < auction.startTime + auction.duration)
            revert AuctionActive(); //拍卖未结束

        auction.isEnded = true;
        nftToActiveAuctionId[auction.nftContract][auction.tokenId] = 0;

        address highestBidder = auction.highestBidder;
        uint256 highestBid = auction.highestBid;
        if (highestBidder != address(0)) {
            IERC721(auction.nftContract).safeTransferFrom(
                address(this),
                highestBidder,
                auction.tokenId
            );
            //记录卖家收益
            userPendingBalances[auction.seller][auction.bidToken] += highestBid;
        } else {
            //流拍
            IERC721(auction.nftContract).safeTransferFrom(
                address(this),
                auction.seller,
                auction.tokenId
            );
        }

        emit AuctionSettled(
            _auctionId,
            highestBidder,
            highestBid,
            auction.bidToken
        );
    }

    /**
     * @notice 提款
     */
    function withdraw(address _token) external nonReentrant {
        uint256 balance = userPendingBalances[msg.sender][_token];
        if (balance == 0) revert InvalidPayment();

        userPendingBalances[msg.sender][_token] = 0;
        if (_token == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: balance}("");
            if (!success) revert TransferFailed();
        } else {
            bool success = IERC20(_token).transfer(msg.sender, balance);
            if (!success) revert TransferFailed();
        }
        emit FundsWithdrawn(msg.sender, _token, balance);
    }

    /**
     * @notice 获取当前最高价的 USD 价值
     * @dev 方便前端在输入框提示“下一笔至少出多少”
     */
    function getMinNextBidUsd(
        uint256 _auctionId
    ) public view returns (uint256) {
        Auction storage auction = auctions[_auctionId];
        if (auction.highestBidder == address(0)) return auction.minUsdValue;

        uint256 highestUsd = getUsdValue(auction.bidToken, auction.highestBid);
        return
            (highestUsd * (BPS_DENOMINATOR + bidIncrementBps)) /
            BPS_DENOMINATOR;
    }

    /**
     * @notice 检查拍卖是否已结束（结合时间与状态）
     */
    function isAuctionLive(uint256 _auctionId) public view returns (bool) {
        Auction storage auction = auctions[_auctionId];
        return (!auction.isEnded &&
            block.timestamp >= auction.startTime &&
            block.timestamp < auction.startTime + auction.duration);
    }

    // 接收NFT
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
