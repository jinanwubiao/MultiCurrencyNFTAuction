# Multi-Currency NFT Auction (UUPS Upgradeable)

基于 **Solidity 0.8.24** 构建的可升级 NFT 拍卖合约。

## 🌟 核心特性

-   **多币种支持**：支持原生 ETH 以及任何符合 ERC20 标准的代币（如 USDC, USDT, WETH）。
-   **USD 价值对齐**：集成 **Chainlink 预言机**，实时计算不同币种的出价价值，确保竞价公平性。
-   **UUPS 代理升级**：采用通用可升级代理标准（Universal Upgradeable Proxy Standard），支持逻辑平滑升级。
-   **异步退款机制**：采用 Pull-payment 模式，规避重入攻击及恶意合约拒绝接收退款导致的拍卖阻塞（DoS）。
-   **Gas 优化**：利用 Solidity 0.8.24 的新特性（如 `ReentrancyGuardTransient`）降低 Gas 消耗。

## 🏗 项目结构

-   `MultiCurrencyAuction.sol`: 核心逻辑合约。
-   `Initializable`, `UUPSUpgradeable`: 升级安全性支持。
-   `AggregatorV3Interface`: Chainlink 价格喂价接口。
-   `userPendingBalances`: 用户资金管理池，支持安全提款。

```
├── README.md
├── foundry.lock
├── foundry.toml
├── lib
│   ├── chainlink-evm
│   ├── forge-std
│   ├── openzeppelin-contracts
│   ├── openzeppelin-contracts-upgradeable
│   └── openzeppelin-foundry-upgrades
├── remappings.txt
├── script
│   └── MultiCurrencyAuction.s.sol
├── src
│   ├── MultiCurrencyAuction.sol
│   ├── MultiCurrencyAuctionV2.sol
│   └── testContracts
└── test
    ├── Auction.sol
    ├── AuctionPrice.sol
    └── Upgrade.sol
```

## 🛠 关键业务逻辑

### 1. 拍卖创建
卖家通过 `createAuction` 上架 NFT，需设定：
-   `minUsdValue`: 以 USD 为单位的起拍价格（18位精度）。
-   `startTime`: 拍卖开始时间（支持预设或立即开始）。
-   `duration`: 持续时间（15分钟至30天）。

### 2. 出价竞拍 (`placeBid`)
-   **单币种校验**：禁止在同一次调用中混合使用 ETH 和参数指定的 ERC20。
-   **价值比较**：系统自动调用 `getUsdValue` 换算当前出价与最高出价的 USD 价值。
-   **最小加价幅度**：新出价必须超过 `当前最高出价 * (1 + bidIncrementBps)`。

### 3. 结算与提款
-   `settleAuction`: 拍卖结束后的交割。NFT 移交给最高出价者，资金进入卖家的提款额度中。
-   `withdraw`: 用户（卖家或竞价失败者）主动提取对应的代币资产。

## 🚀 部署与初始化

### 环境要求
-   **Foundry**: 推荐使用最新版本。
-   **依赖库**: 
    ```bash
    forge install foundry-rs/forge-std
    forge install OpenZeppelin/openzeppelin-foundry-upgrades
    forge install OpenZeppelin/openzeppelin-contracts-upgradeable
    forge install smartcontractkit/chainlink-evm@contracts-v1.5.0
    ```

### 部署指令
使用 Foundry 脚本部署逻辑合约并挂载代理：

```bash
# 部署至指定网络
forge script script/DeployAuction.s.sol:DeployAuction \
    --rpc-url <YOUR_RPC_URL> \
    --private-key <YOUR_PRIVATE_KEY> \
    --broadcast \
    --verify \
    -vvvv

# anvil网络
# 设置私钥
export PRIVATE_KEY=your_private_key
# 模拟运行
forge script script/MultiCurrencyAuction.s.sol --rpc-url http://127.0.0.1:8545
# 部署执行
forge script script/MultiCurrencyAuction.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
# 查看部署的合约代码
cast code $CONTRACT_ADDRESS --rpc-url http://127.0.0.1:8545
# 调用合约函数
cast call $CONTRACT_ADDRESS "bidIncrementBps()(uint256)" --rpc-url http://127.0.0.1:8545
# 完整部署
forge script script/MultiCurrencyAuction.s.sol \
  --rpc-url sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --slow
```


### 初始化配置 (Cast 示例)
部署后必须通过 Proxy 地址配置预言机才能开始拍卖：

```bash
# 配置 ETH/USD 报价源 (以 Sepolia 为例)
cast send <PROXY_ADDRESS> "setPriceFeed(address,address)" \
    0x0000000000000000000000000000000000000000 \
    0x694AA1769357215DE4FAC081bf1f309aDC325306 \
    --rpc-url <YOUR_RPC_URL> \
    --private-key <YOUR_PRIVATE_KEY>
```

## 🧪 测试说明

项目包含完整的单元测试与时间模拟测试：

```bash
# 运行所有测试
forge test
```

**测试重点内容：**
-   **精度验证**：验证 6 位精度代币（如USDC）与 18 位精度代币在 USD 换算时的一致性。
-   **安全撤回**：验证竞价失败后，用户能否通过 `withdraw` 安全取回资金。

## 🔒 安全说明

1.  **Stale Price 检查**：预言机数据超过 25 小时未更新将禁止操作。
2.  **Transient Reentrancy Guard**：使用临时存储防止跨函数重入。
3.  **Mixed Payment Protection**：拦截歧义参数，防止资金丢失。

## 📄 开源协议

UNLICENSED
