// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title FeeRouter
/// @notice 薄转发：用户在同一笔交易里先经过本合约，再进 Pancake V2 / V3、Flap 或 FOUR.meme。
/// @dev 不做报价。feeSide：0 不抽，1 从付出的输入抽，2 从换回的计价币抽。暂停时费率按 0，原样转发。
contract FeeRouter {
    uint256 public constant BPS = 10_000;
    /// @notice owner 能改的费率上限，避免误设成接近全部。
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant DEFAULT_FEE_BPS = 35;

    address public owner;
    address public treasury;
    uint256 public feeBps;
    bool public paused;
    address public immutable wbnb;

    /// @dev FOUR.meme 官方地址（BSC）。
    address public constant FOUR_HELPER = 0xF251F83e40a78868FcfA3FA4599Dad6494E46034;
    address public constant FOUR_TM_V1 = 0xEC4549caDcE5DA21Df6E6422d448034B5233bFbC;
    address public constant FOUR_TM_V2 = 0x5c952063c7fc8610FFDB798152D69F0B9550762b;

    uint256 private locked;

    error NotOwner();
    error ZeroAddress();
    error BadPath();
    error BadFee();
    error ValueMismatch();
    error TransferFailed();
    error Reentered();

    uint8 private constant VENUE_V2 = 0;
    uint8 private constant VENUE_V3 = 1;
    uint8 private constant VENUE_FLAP = 2;
    uint8 private constant VENUE_FOUR = 3;

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasurySet(address indexed treasury);
    event FeeBpsSet(uint256 feeBps);
    event PausedSet(bool paused);
    event FeeCollected(address indexed payer, address indexed token, uint256 amount);
    /// @notice 每一笔成功转发都发。暂停或费率为 0 时 feeAmount 为 0。token 为 address(0) 表示 BNB。
    /// @param venue 0 Pancake V2，1 Pancake V3，2 Flap，3 FOUR.meme。
    /// @param amountOutMin 调用时传入的最小输出，不是实际到账。
    event TradeRouted(
        address indexed trader,
        address indexed routerOrVenue,
        uint8 venue,
        uint8 feeSide,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 feeAmount,
        address feeToken
    );
    event Rescued(address indexed token, address indexed to, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked == 1) revert Reentered();
        locked = 1;
        _;
        locked = 0;
    }

    constructor(address initialOwner, address initialTreasury, address wrappedNative) {
        if (initialOwner == address(0) || initialTreasury == address(0) || wrappedNative == address(0)) revert ZeroAddress();
        owner = initialOwner;
        treasury = initialTreasury;
        wbnb = wrappedNative;
        feeBps = DEFAULT_FEE_BPS;
        emit OwnerTransferred(address(0), initialOwner);
        emit TreasurySet(initialTreasury);
        emit FeeBpsSet(DEFAULT_FEE_BPS);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        treasury = next;
        emit TreasurySet(next);
    }

    function setFeeBps(uint256 next) external onlyOwner {
        if (next > MAX_FEE_BPS) revert BadFee();
        feeBps = next;
        emit FeeBpsSet(next);
    }

    /// @notice 暂停后买卖都按 0 费率原样转发，不再把输入或输出拆给 treasury。
    function setPaused(bool next) external onlyOwner {
        paused = next;
        emit PausedSet(next);
    }

    /// @notice token 为 address(0) 时抽回误转的 BNB。
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) _payBnb(to, amount);
        else _payToken(token, to, amount);
        emit Rescued(token, to, amount);
    }

    /// @param feeSide 0 不抽，1 从输入抽，2 从输出抽。path 与直连 Pancake V2 相同，原生币用 WBNB 占位。
    function swapV2(
        address router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline,
        uint8 feeSide
    ) external payable nonReentrant {
        if (router == address(0)) revert ZeroAddress();
        if (path.length < 2 || feeSide > 2) revert BadPath();
        if (msg.value > 0) _v2EthIn(router, amountIn, amountOutMin, path, deadline, feeSide);
        else _v2TokenIn(router, amountIn, amountOutMin, path, deadline, feeSide);
    }

    function _v2EthIn(
        address router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline,
        uint8 feeSide
    ) private {
        if (msg.value != amountIn || path[0] != wbnb) revert ValueMismatch();
        uint256 pay = amountIn;
        uint256 feeAmount;
        if (feeSide == 1) (feeAmount, pay) = _takeBnb(amountIn);
        IPancakeV2(router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: pay}(amountOutMin, path, msg.sender, deadline);
        RouteLog memory log;
        log.venue = router;
        log.kind = VENUE_V2;
        log.feeSide = feeSide;
        log.tokenIn = address(0);
        log.tokenOut = path[path.length - 1];
        log.amountIn = amountIn;
        log.amountOutMin = amountOutMin;
        log.feeAmount = feeAmount;
        _routed(log);
    }

    function _v2TokenIn(
        address router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline,
        uint8 feeSide
    ) private {
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        _pull(tokenIn, msg.sender, amountIn);
        uint256 poolIn = amountIn;
        uint256 feeAmount;
        address feeToken;
        if (feeSide == 1) (feeAmount, poolIn) = _takeToken(tokenIn, amountIn);
        _approve(tokenIn, router, poolIn);
        if (tokenOut == wbnb && feeSide == 2) {
            uint256 beforeBal = address(this).balance;
            IPancakeV2(router).swapExactTokensForETHSupportingFeeOnTransferTokens(poolIn, amountOutMin, path, address(this), deadline);
            feeAmount = _skimBnb(address(this).balance - beforeBal);
            tokenOut = address(0);
        } else if (feeSide == 2) {
            uint256 beforeBal = _balanceOf(tokenOut);
            IPancakeV2(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(poolIn, amountOutMin, path, address(this), deadline);
            feeAmount = _skimToken(tokenOut, _balanceOf(tokenOut) - beforeBal);
            feeToken = tokenOut;
        } else if (tokenOut == wbnb) {
            IPancakeV2(router).swapExactTokensForETHSupportingFeeOnTransferTokens(poolIn, amountOutMin, path, msg.sender, deadline);
            tokenOut = address(0);
        } else {
            IPancakeV2(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(poolIn, amountOutMin, path, msg.sender, deadline);
        }
        if (feeSide == 1) feeToken = tokenIn;
        RouteLog memory log;
        log.venue = router;
        log.kind = VENUE_V2;
        log.feeSide = feeSide;
        log.tokenIn = tokenIn;
        log.tokenOut = tokenOut;
        log.amountIn = amountIn;
        log.amountOutMin = amountOutMin;
        log.feeAmount = feeAmount;
        log.feeToken = feeToken;
        _routed(log);
    }

    struct V3Swap {
        address router;
        address tokenIn;
        address tokenOut;
        uint24 poolFee;
        uint256 amountIn;
        uint256 amountOutMin;
        uint160 sqrtPriceLimitX96;
        uint256 deadline;
        bool payNative;
        bool recvNative;
        uint8 feeSide;
    }

    function swapV3(V3Swap calldata swap) external payable nonReentrant {
        if (swap.router == address(0) || swap.tokenOut == address(0)) revert ZeroAddress();
        if (swap.feeSide > 2) revert BadPath();
        address tokenIn = swap.tokenIn;
        address tokenOut = swap.tokenOut;
        uint256 feeAmount;
        address feeToken = address(0);
        if (swap.payNative) {
            if (msg.value != swap.amountIn) revert ValueMismatch();
            uint256 pay = swap.amountIn;
            if (swap.feeSide == 1) (feeAmount, pay) = _takeBnb(swap.amountIn);
            IWBNB(wbnb).deposit{value: pay}();
            _approve(wbnb, swap.router, pay);
            _v3(swap, wbnb, pay, msg.sender);
            tokenIn = address(0);
        } else {
            if (swap.tokenIn == address(0)) revert ZeroAddress();
            _pull(swap.tokenIn, msg.sender, swap.amountIn);
            uint256 poolIn = swap.amountIn;
            if (swap.feeSide == 1) (feeAmount, poolIn) = _takeToken(swap.tokenIn, swap.amountIn);
            _approve(swap.tokenIn, swap.router, poolIn);
            if (swap.recvNative) {
                uint256 before = _balanceOf(wbnb);
                _v3(swap, swap.tokenIn, poolIn, address(this));
                uint256 gained = _balanceOf(wbnb) - before;
                IWBNB(wbnb).withdraw(gained);
                if (swap.feeSide == 2) feeAmount = _skimBnb(gained);
                else _payBnb(msg.sender, gained);
                tokenOut = address(0);
            } else if (swap.feeSide == 2) {
                uint256 before = _balanceOf(swap.tokenOut);
                _v3(swap, swap.tokenIn, poolIn, address(this));
                feeAmount = _skimToken(swap.tokenOut, _balanceOf(swap.tokenOut) - before);
            } else {
                _v3(swap, swap.tokenIn, poolIn, msg.sender);
            }
        }
        if (swap.feeSide == 1) feeToken = tokenIn;
        else if (swap.feeSide == 2) feeToken = tokenOut;
        RouteLog memory log;
        log.venue = swap.router;
        log.kind = VENUE_V3;
        log.feeSide = swap.feeSide;
        log.tokenIn = tokenIn;
        log.tokenOut = tokenOut;
        log.amountIn = swap.amountIn;
        log.amountOutMin = swap.amountOutMin;
        log.feeAmount = feeAmount;
        log.feeToken = feeToken;
        _routed(log);
    }

    /// @param inputToken address(0) 表示 BNB。Flap 把输出打给调用者，本合约再转给用户。
    function swapFlap(
        address portal,
        address inputToken,
        address outputToken,
        uint256 amountIn,
        uint256 amountOutMin,
        uint8 feeSide
    ) external payable nonReentrant {
        if (portal == address(0) || feeSide > 2) revert BadPath();
        uint256 poolIn = amountIn;
        uint256 feeAmount;
        address feeToken = address(0);
        if (inputToken == address(0)) {
            if (msg.value != amountIn) revert ValueMismatch();
            if (feeSide == 1) (feeAmount, poolIn) = _takeBnb(amountIn);
        } else {
            _pull(inputToken, msg.sender, amountIn);
            if (feeSide == 1) (feeAmount, poolIn) = _takeToken(inputToken, amountIn);
            _approve(inputToken, portal, poolIn);
        }
        uint256 valueIn = inputToken == address(0) ? poolIn : 0;
        uint256 bnbBefore = address(this).balance - valueIn;
        uint256 tokenBefore = outputToken == address(0) ? 0 : _balanceOf(outputToken);
        IFlap(portal).swapExactInput{value: valueIn}(
            IFlap.ExactInputParams({
                inputToken: inputToken,
                outputToken: outputToken,
                inputAmount: poolIn,
                minOutputAmount: amountOutMin,
                permitData: ""
            })
        );
        if (outputToken == address(0)) {
            uint256 got = address(this).balance - bnbBefore;
            if (feeSide == 2) feeAmount = _skimBnb(got);
            else _payBnb(msg.sender, got);
        } else {
            uint256 gotToken = _balanceOf(outputToken) - tokenBefore;
            if (feeSide == 2) feeAmount = _skimToken(outputToken, gotToken);
            else _payToken(outputToken, msg.sender, gotToken);
        }
        if (feeSide == 1) feeToken = inputToken;
        else if (feeSide == 2) feeToken = outputToken;
        RouteLog memory log;
        log.venue = portal;
        log.kind = VENUE_FLAP;
        log.feeSide = feeSide;
        log.tokenIn = inputToken;
        log.tokenOut = outputToken;
        log.amountIn = amountIn;
        log.amountOutMin = amountOutMin;
        log.feeAmount = feeAmount;
        log.feeToken = feeToken;
        _routed(log);
    }


    /// @notice FOUR.meme 内盘。tokenManager 必须是 V1/V2 官方地址，且与 Helper3.getTokenInfo 一致、未毕业。
    /// @param quoteToken address(0) = BNB。买入 feeSide=1 从输入抽；卖出 feeSide=2 从输出抽。
    /// @param isBuy true=用计价币买 meme；false=卖 meme 换计价币。
    function swapFour(
        address tokenManager,
        address memeToken,
        address quoteToken,
        uint256 amountIn,
        uint256 amountOutMin,
        bool isBuy,
        uint8 feeSide
    ) external payable nonReentrant {
        if (memeToken == address(0) || feeSide > 2) revert BadPath();
        _assertFourManager(tokenManager, memeToken, quoteToken);
        if (isBuy) _fourBuy(tokenManager, memeToken, quoteToken, amountIn, amountOutMin, feeSide);
        else _fourSell(tokenManager, memeToken, quoteToken, amountIn, amountOutMin, feeSide);
    }

    function _assertFourManager(address tokenManager, address memeToken, address quoteToken) private view {
        if (tokenManager != FOUR_TM_V1 && tokenManager != FOUR_TM_V2) revert BadPath();
        (
            ,
            address tm,
            address quote,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            bool liquidityAdded
        ) = IFourHelper(FOUR_HELPER).getTokenInfo(memeToken);
        if (liquidityAdded || tm != tokenManager || quote != quoteToken) revert BadPath();
    }

    function _fourBuy(
        address tokenManager,
        address memeToken,
        address quoteToken,
        uint256 amountIn,
        uint256 amountOutMin,
        uint8 feeSide
    ) private {
        uint256 poolIn = amountIn;
        uint256 feeAmount = 0;
        address feeToken = address(0);
        if (quoteToken == address(0)) {
            if (msg.value != amountIn) revert ValueMismatch();
            if (feeSide == 1) (feeAmount, poolIn) = _takeBnb(amountIn);
        } else {
            if (msg.value != 0) revert ValueMismatch();
            _pull(quoteToken, msg.sender, amountIn);
            if (feeSide == 1) (feeAmount, poolIn) = _takeToken(quoteToken, amountIn);
            _approve(quoteToken, tokenManager, poolIn);
        }
        uint256 valueIn = quoteToken == address(0) ? poolIn : 0;
        address recipient = feeSide == 2 ? address(this) : msg.sender;
        uint256 memeBefore = feeSide == 2 ? _balanceOf(memeToken) : 0;
        if (tokenManager == FOUR_TM_V2) {
            IFourTM2(tokenManager).buyTokenAMAP{value: valueIn}(memeToken, recipient, poolIn, amountOutMin);
        } else {
            IFourTM1(tokenManager).purchaseTokenAMAP{value: valueIn}(0, memeToken, recipient, poolIn, amountOutMin);
        }
        if (feeSide == 2) {
            feeAmount = _skimToken(memeToken, _balanceOf(memeToken) - memeBefore);
            feeToken = memeToken;
        } else if (feeSide == 1) {
            feeToken = quoteToken;
        }
        RouteLog memory log;
        log.venue = tokenManager;
        log.kind = VENUE_FOUR;
        log.feeSide = feeSide;
        log.tokenIn = quoteToken;
        log.tokenOut = memeToken;
        log.amountIn = amountIn;
        log.amountOutMin = amountOutMin;
        log.feeAmount = feeAmount;
        log.feeToken = feeToken;
        _routed(log);
    }

    function _fourSell(
        address tokenManager,
        address memeToken,
        address quoteToken,
        uint256 amountIn,
        uint256 amountOutMin,
        uint8 feeSide
    ) private {
        if (msg.value != 0) revert ValueMismatch();
        _pull(memeToken, msg.sender, amountIn);
        // feeSide==1 on sell would skim meme before sell; not used by mm-web (sells use feeSide=2).
        uint256 poolIn = amountIn;
        uint256 feeAmount = 0;
        address feeToken = address(0);
        if (feeSide == 1) (feeAmount, poolIn) = _takeToken(memeToken, amountIn);
        _approve(memeToken, tokenManager, poolIn);
        uint256 bnbBefore = address(this).balance;
        uint256 tokenBefore = quoteToken == address(0) ? 0 : _balanceOf(quoteToken);
        if (tokenManager == FOUR_TM_V2) {
            IFourTM2(tokenManager).sellToken(0, memeToken, poolIn, amountOutMin, 0, address(0));
        } else {
            IFourTM1(tokenManager).saleToken(memeToken, poolIn);
        }
        if (quoteToken == address(0)) {
            uint256 got = address(this).balance - bnbBefore;
            if (tokenManager == FOUR_TM_V1 && got < amountOutMin) revert BadPath();
            if (feeSide == 2) feeAmount = _skimBnb(got);
            else _payBnb(msg.sender, got);
        } else {
            uint256 got = _balanceOf(quoteToken) - tokenBefore;
            if (tokenManager == FOUR_TM_V1 && got < amountOutMin) revert BadPath();
            if (feeSide == 2) feeAmount = _skimToken(quoteToken, got);
            else _payToken(quoteToken, msg.sender, got);
        }
        if (feeSide == 1) feeToken = memeToken;
        else if (feeSide == 2) feeToken = quoteToken;
        RouteLog memory log;
        log.venue = tokenManager;
        log.kind = VENUE_FOUR;
        log.feeSide = feeSide;
        log.tokenIn = memeToken;
        log.tokenOut = quoteToken;
        log.amountIn = amountIn;
        log.amountOutMin = amountOutMin;
        log.feeAmount = feeAmount;
        log.feeToken = feeToken;
        _routed(log);
    }

    receive() external payable {}

    function _v3(V3Swap calldata swap, address tokenIn, uint256 amountIn, address recipient) private {
        IPancakeV3(swap.router).exactInputSingle(
            IPancakeV3.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: swap.tokenOut,
                fee: swap.poolFee,
                recipient: recipient,
                deadline: swap.deadline,
                amountIn: amountIn,
                amountOutMinimum: swap.amountOutMin,
                sqrtPriceLimitX96: swap.sqrtPriceLimitX96
            })
        );
    }

    struct RouteLog {
        address venue;
        uint8 kind;
        uint8 feeSide;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 feeAmount;
        address feeToken;
    }

    function _routed(RouteLog memory log) private {
        emit TradeRouted(msg.sender, log.venue, log.kind, log.feeSide, log.tokenIn, log.tokenOut, log.amountIn, log.amountOutMin, log.feeAmount, log.feeToken);
    }

    function _takeBnb(uint256 amount) private returns (uint256 fee, uint256 net) {
        (fee, net) = _split(amount);
        _collectBnb(fee);
    }

    function _takeToken(address token, uint256 amount) private returns (uint256 fee, uint256 net) {
        (fee, net) = _split(amount);
        _collectToken(token, fee);
    }

    function _split(uint256 amount) private view returns (uint256 fee, uint256 net) {
        uint256 bps = paused ? 0 : feeBps;
        fee = (amount * bps) / BPS;
        net = amount - fee;
    }

    function _collectBnb(uint256 fee) private {
        if (fee == 0) return;
        _payBnb(treasury, fee);
        emit FeeCollected(msg.sender, address(0), fee);
    }

    function _collectToken(address token, uint256 fee) private {
        if (fee == 0) return;
        _payToken(token, treasury, fee);
        emit FeeCollected(msg.sender, token, fee);
    }

    function _skimBnb(uint256 got) private returns (uint256 fee) {
        uint256 net;
        (fee, net) = _split(got);
        _collectBnb(fee);
        _payBnb(msg.sender, net);
    }

    function _skimToken(address token, uint256 got) private returns (uint256 fee) {
        uint256 net;
        (fee, net) = _split(got);
        _collectToken(token, fee);
        _payToken(token, msg.sender, net);
    }

    function _pull(address token, address from, uint256 amount) private {
        _move(token, abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount));
    }

    function _payToken(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        _move(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
    }

    function _payBnb(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _approve(address token, address spender, uint256 amount) private {
        _move(token, abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        _move(token, abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
    }

    function _move(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _balanceOf(address token) private view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IPancakeV2 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

interface IPancakeV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IFlap {
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256);
}

interface IFourHelper {
    function getTokenInfo(address token)
        external
        view
        returns (
            uint256 version,
            address tokenManager,
            address quote,
            uint256 lastPrice,
            uint256 tradingFeeRate,
            uint256 minTradingFee,
            uint256 launchTime,
            uint256 offers,
            uint256 maxOffers,
            uint256 funds,
            uint256 maxFunds,
            bool liquidityAdded
        );
}

interface IFourTM2 {
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount) external payable;
    function sellToken(uint256 origin, address token, uint256 amount, uint256 minFunds, uint256 feeRate, address feeRecipient) external;
}

interface IFourTM1 {
    function purchaseTokenAMAP(uint256 origin, address token, address to, uint256 funds, uint256 minAmount) external payable;
    function saleToken(address token, uint256 amount) external;
}
