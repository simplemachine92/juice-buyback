// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "../interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController3_1.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBDirectory.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol";
import "@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol";

import {JBDelegateMetadataHelper} from "@jbx-protocol/juice-delegate-metadata-lib/src/JBDelegateMetadataHelper.sol";

import "@paulrberg/contracts/math/PRBMath.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "forge-std/Test.sol";

import "../JBBuybackDelegate.sol";

/**
 * @notice Unit tests for the JBBuybackDelegate contract.
 *
 */
contract TestJBBuybackDelegate_Units is Test {
    using stdStorage for StdStorage;

    ForTest_BuybackDelegate delegate;

    event BuybackDelegate_Swap(uint256 projectId, uint256 amountEth, uint256 amountOut);
    event BuybackDelegate_Mint(uint256 projectId);
    event BuybackDelegate_SecondsAgoIncrease(uint256 oldSecondsAgo, uint256 newSecondsAgo);
    event BuybackDelegate_TwapDeltaChanged(uint256 oldTwapDelta, uint256 newTwapDelta);
    event BuybackDelegate_PendingSweep(address indexed beneficiary, uint256 amount);

    // Use the L1 UniswapV3Pool jbx/eth 1% fee for create2 magic
    IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IERC20 projectToken = IERC20(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address _uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    uint24 fee = 10000;

    IJBPayoutRedemptionPaymentTerminal3_1_1 jbxTerminal =
        IJBPayoutRedemptionPaymentTerminal3_1_1(makeAddr("IJBPayoutRedemptionPaymentTerminal3_1"));
    IJBProjects projects = IJBProjects(makeAddr("IJBProjects"));
    IJBOperatorStore operatorStore = IJBOperatorStore(makeAddr("IJBOperatorStore"));
    IJBController3_1 controller = IJBController3_1(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    JBDelegateMetadataHelper metadataHelper = new JBDelegateMetadataHelper();

    address terminalStore = makeAddr("terminalStore");

    address dude = makeAddr("dude");
    address owner = makeAddr("owner");

    uint32 secondsAgo = 100;
    uint256 twapDelta = 100;

    JBPayParamsData payParams = JBPayParamsData({
        terminal: jbxTerminal,
        payer: dude,
        amount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        projectId: 69,
        currentFundingCycleConfiguration: 0,
        beneficiary: dude,
        weight: 69,
        reservedRate: 0,
        memo: "myMemo",
        metadata: ""
    });

    JBDidPayData3_1_1 didPayData = JBDidPayData3_1_1({
        payer: dude,
        projectId: 69,
        currentFundingCycleConfiguration: 0,
        amount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        forwardedAmount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        projectTokenCount: 69,
        beneficiary: dude,
        preferClaimedTokens: true,
        memo: "myMemo",
        dataSourceMetadata: "",
        payerMetadata: ""
    });

    function setUp() external {
        vm.etch(address(projectToken), "6969");
        vm.etch(address(weth), "6969");
        vm.etch(address(pool), "6969");
        vm.etch(address(jbxTerminal), "6969");
        vm.etch(address(projects), "6969");
        vm.etch(address(operatorStore), "6969");
        vm.etch(address(controller), "6969");
        vm.etch(address(directory), "6969");

        vm.label(address(pool), "pool");
        vm.label(address(projectToken), "projectToken");
        vm.label(address(weth), "weth");

        vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.store, ()), abi.encode(terminalStore));

        vm.prank(owner);
        delegate = new ForTest_BuybackDelegate({
      _projectToken: projectToken,
      _weth: weth,
      _factory: _uniswapFactory,
      _fee: fee, // 1 % fee
      _secondsAgo: secondsAgo,
      _twapDelta: twapDelta,
      _directory: directory,
      _controller: controller,
      _id: bytes4(hex'69')
    });
    }

    /**
     * @notice Test payParams when a quote is provided as metadata
     *
     * @dev    _tokenCount == weight, as we use a value of 1.
     */
    function test_payParams_callWithQuote(uint256 _tokenCount, uint256 _swapOutCount, uint256 _slippage) public {
        // Avoid overflow when computing slippage (cannot swap uint256.max tokens)
        _swapOutCount = bound(_swapOutCount, 1, type(uint240).max);

        _slippage = bound(_slippage, 1, 10000);

        // Take max slippage into account
        uint256 _swapQuote = _swapOutCount - ((_swapOutCount * _slippage) / 10000);

        // Pass the quote as metadata
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_swapOutCount, _slippage);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4(hex"69");

        // Generate the metadata
        bytes memory _metadata = metadataHelper.createMetadata(_ids, _data);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = _metadata;

        // Returned values to catch:
        JBPayDelegateAllocation3_1_1[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _swapQuote) {
            // No delegate allocation returned
            assertEq(_allocationsReturned.length, 0);

            // weight unchanged
            assertEq(_weightReturned, _tokenCount);
        }
        // Swap pathway (return the delegate allocation)
        else {
            assertEq(_allocationsReturned.length, 1);
            assertEq(address(_allocationsReturned[0].delegate), address(delegate));
            assertEq(_allocationsReturned[0].amount, 1 ether);
            assertEq(_allocationsReturned[0].metadata, abi.encode(_tokenCount, _swapQuote));

            assertEq(_weightReturned, 0);
        }

        // Same memo in any case
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test payParams when no quote is provided, falling back on the pool twap
     *
     * @dev    This bypass testing Uniswap Oracle lib by re-using the internal _getQuote
     */
    function test_payParams_useTwap(uint256 _tokenCount) public {
        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = "";

        // Mock the pool being unlocked
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, true));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Mock the pool's twap
        uint32[] memory _secondsAgos = new uint32[](2);
        _secondsAgos[0] = secondsAgo;
        _secondsAgos[1] = 0;

        uint160[] memory _secondPerLiquidity = new uint160[](2);
        _secondPerLiquidity[0] = 100;
        _secondPerLiquidity[1] = 1000;

        int56[] memory _tickCumulatives = new int56[](2);
        _tickCumulatives[0] = 100;
        _tickCumulatives[1] = 1000;

        vm.mockCall(
            address(pool),
            abi.encodeCall(pool.observe, (_secondsAgos)),
            abi.encode(_tickCumulatives, _secondPerLiquidity)
        );
        vm.expectCall(address(pool), abi.encodeCall(pool.observe, (_secondsAgos)));

        // Returned values to catch:
        JBPayDelegateAllocation3_1_1[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // Bypass testing uniswap oracle lib
        uint256 _twapAmountOut = delegate.ForTest_getQuote(1 ether);

        // Mint pathway if more token received when minting:
        if (_tokenCount >= _twapAmountOut) {
            // No delegate allocation returned
            assertEq(_allocationsReturned.length, 0);

            // weight unchanged
            assertEq(_weightReturned, _tokenCount);
        }
        // Swap pathway (set the mutexes and return the delegate allocation)
        else {
            assertEq(_allocationsReturned.length, 1);
            assertEq(address(_allocationsReturned[0].delegate), address(delegate));
            assertEq(_allocationsReturned[0].amount, 1 ether);
            assertEq(_allocationsReturned[0].metadata, abi.encode(_tokenCount, _twapAmountOut));

            assertEq(_weightReturned, 0);
        }

        // Same memo in any case
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test payParams with a twap but locked pool, which should then mint
     */
    function test_payParams_useTwapLockedPool(uint256 _tokenCount) public {
        _tokenCount = bound(_tokenCount, 1, type(uint120).max);

        // Set the relevant payParams data
        payParams.weight = _tokenCount;
        payParams.metadata = "";

        // Mock the pool being unlocked
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, false));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Returned values to catch:
        JBPayDelegateAllocation3_1_1[] memory _allocationsReturned;
        string memory _memoReturned;
        uint256 _weightReturned;

        // Test: call payParams
        vm.prank(terminalStore);
        (_weightReturned, _memoReturned, _allocationsReturned) = delegate.payParams(payParams);

        // No delegate allocation returned
        assertEq(_allocationsReturned.length, 0);

        // weight unchanged
        assertEq(_weightReturned, _tokenCount);

        // Same memo
        assertEq(_memoReturned, payParams.memo);
    }

    /**
     * @notice Test didPay with token received from swapping
     */
    function test_didPay_swap(uint256 _tokenCount, uint256 _twapQuote, uint256 _reservedRate) public {
        // Bound to avoid overflow and insure swap quote > mint quote
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);
        _reservedRate = bound(_reservedRate, 0, 10000);

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote);

        // The amount the beneficiary should receive
        uint256 _nonReservedToken =
            PRBMath.mulDiv(_twapQuote, JBConstants.MAX_RESERVED_RATE - _reservedRate, JBConstants.MAX_RESERVED_RATE);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // mock the transfer call
        vm.mockCall(
            address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _nonReservedToken)), abi.encode(true)
        );

        // mock the call to the directory, to get the controller
        vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.directory, ()), abi.encode(address(directory)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.controllerOf, (didPayData.projectId)),
            abi.encode(address(controller))
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
            abi.encode(true)
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, true, true)
            ),
            abi.encode(true)
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(didPayData.projectId, didPayData.amount.value, _twapQuote);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay when eth leftover from swap
     */
    function test_didPay_keepTrackOfETHToSweep() public {
        uint256 _tokenCount = 10;
        uint256 _twapQuote = 11;

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote);

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode(-int256(_twapQuote), -int256(_twapQuote))
        );

        // Mock the project token transfer
        vm.mockCall(address(projectToken), abi.encodeCall(projectToken.transfer, (dude, _twapQuote)), abi.encode(true));

        // Add some leftover (nothing will be wrapped/transfered as it happens in the callback)
        vm.deal(address(delegate), 10 ether);

        // Add a previous leftover, to test the incremental accounting (ie 5 out of 10 were there)
        stdstore.target(address(delegate)).sig("sweepBalance()").checked_write(5 ether);

        // Out of these 5, 1 was for payer
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address)").with_key(didPayData.payer).checked_write(
            1 ether
        );

        // mock the call to the directory, to get the controller
        vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.directory, ()), abi.encode(address(directory)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.controllerOf, (didPayData.projectId)),
            abi.encode(address(controller))
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(delegate), didPayData.projectId, _twapQuote, "", true)),
            abi.encode(true)
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (didPayData.projectId, _twapQuote, address(dude), didPayData.memo, true, true)
            ),
            abi.encode(true)
        );

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_PendingSweep(dude, 5 ether);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);

        // Check: correct overall sweep balance?
        assertEq(delegate.sweepBalance(), 10 ether);

        // Check: correct dude sweep balance (1 previous plus 5 from now)?
        assertEq(delegate.sweepBalanceOf(dude), 6 ether);
    }

    /**
     * @notice Test didPay with swap reverting, should then mint
     */

    function test_didPay_swapRevert(uint256 _tokenCount, uint256 _twapQuote) public {
        _tokenCount = bound(_tokenCount, 2, type(uint256).max - 1);
        _twapQuote = bound(_twapQuote, _tokenCount + 1, type(uint256).max);

        // The metadata coming from payParams(..)
        didPayData.dataSourceMetadata = abi.encode(_tokenCount, _twapQuote);

        // mock the swap call reverting
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(delegate),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(_twapQuote)
                )
            ),
            abi.encode("no swap")
        );

        // mock the call to the directory, to get the controller
        vm.mockCall(address(jbxTerminal), abi.encodeCall(jbxTerminal.directory, ()), abi.encode(address(directory)));
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.controllerOf, (didPayData.projectId)),
            abi.encode(address(controller))
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(jbxTerminal)))),
            abi.encode(true)
        );

        // mock the minting call - this uses the weight and not the (potentially faulty) quote or twap
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (didPayData.projectId, _tokenCount, dude, didPayData.memo, didPayData.preferClaimedTokens, true)
            ),
            abi.encode(true)
        );

        // mock the add to balance addint eth back to the terminal (need to deal eth as this transfer really occurs in test)
        vm.deal(address(delegate), 1 ether);
        vm.mockCall(
            address(jbxTerminal),
            abi.encodeCall(
                IJBPaymentTerminal(address(jbxTerminal)).addToBalanceOf,
                (didPayData.projectId, 1 ether, JBTokens.ETH, "", "")
            ),
            ""
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Mint(didPayData.projectId);

        vm.prank(address(jbxTerminal));
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test didPay revert if wrong caller
     */
    function test_didPay_revertIfWrongCaller(address _notTerminal) public {
        vm.assume(_notTerminal != address(jbxTerminal));

        // mock call to fail at the authorization check since directory has no bytecode
        vm.mockCall(
            address(directory),
            abi.encodeCall(directory.isTerminalOf, (didPayData.projectId, IJBPaymentTerminal(address(_notTerminal)))),
            abi.encode(false)
        );

        vm.expectRevert(abi.encodeWithSelector(JBBuybackDelegate.JuiceBuyback_Unauthorized.selector));

        vm.prank(_notTerminal);
        delegate.didPay(didPayData);
    }

    /**
     * @notice Test uniswapCallback
     *
     * @dev    2 branches: project token is 0 or 1 in the pool slot0
     */
    function test_uniswapCallback() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25;

        /**
         * First branch
         */
        delegate = new ForTest_BuybackDelegate({
      _projectToken: projectToken,
      _weth: weth,
      _factory: _uniswapFactory,
      _fee: fee,
      _secondsAgo: secondsAgo,
      _twapDelta: twapDelta,
      _directory: directory,
      _controller: controller,
      _id: bytes4(hex'69')
    });

        // If project is token0, then received is delta0 (the negative value)
        (_delta0, _delta1) = address(projectToken) < address(weth) ? (_delta0, _delta1) : (_delta1, _delta0);

        // mock and expect weth calls, this should transfer from delegate to pool (positive delta in the callback)
        vm.mockCall(address(weth), abi.encodeCall(weth.deposit, ()), "");

        vm.mockCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            ),
            abi.encode(true)
        );

        vm.prank(address(pool));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));

        /**
         * Second branch
         */

        // Invert both contract addresses, to swap token0 and token1 (this will NOT modify the pool address)
        (projectToken, weth) = (JBToken(address(weth)), IWETH9(address(projectToken)));

        delegate = new ForTest_BuybackDelegate({
      _projectToken: projectToken,
      _weth: weth,
      _factory: _uniswapFactory,
      _fee: fee,
      _secondsAgo: secondsAgo,
      _twapDelta: twapDelta,
      _directory: directory,
      _controller: controller,
      _id: bytes4(hex'69')
    });

        // mock and expect weth calls, this should transfer from delegate to pool (positive delta in the callback)
        vm.mockCall(address(weth), abi.encodeCall(weth.deposit, ()), "");

        vm.mockCall(
            address(weth),
            abi.encodeCall(
                weth.transfer, (address(pool), uint256(address(projectToken) < address(weth) ? _delta1 : _delta0))
            ),
            abi.encode(true)
        );

        vm.prank(address(pool));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));
    }

    /**
     * @notice Test uniswapCallback revert if wrong caller
     */
    function test_uniswapCallback_revertIfWrongCaller() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25;

        vm.expectRevert(abi.encodeWithSelector(JBBuybackDelegate.JuiceBuyback_Unauthorized.selector));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));
    }

    /**
     * @notice Test uniswapCallback revert if max slippage
     */
    function test_uniswapCallback_revertIfMaxSlippage() public {
        int256 _delta0 = -1 ether;
        int256 _delta1 = 1 ether;
        uint256 _minReceived = 25 ether;

        // If project is token0, then received is delta0 (the negative value)
        (_delta0, _delta1) = address(projectToken) < address(weth) ? (_delta0, _delta1) : (_delta1, _delta0);

        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(JBBuybackDelegate.JuiceBuyback_MaximumSlippage.selector));
        delegate.uniswapV3SwapCallback(_delta0, _delta1, abi.encode(_minReceived));
    }

    /**
     * @notice Test sweep
     */
    function test_sweep(uint256 _delegateLeftover, uint256 _dudeLeftover) public {
        _dudeLeftover = bound(_dudeLeftover, 0, _delegateLeftover);

        // Add the ETH
        vm.deal(address(delegate), _delegateLeftover);

        // Store the delegate leftover
        stdstore.target(address(delegate)).sig("sweepBalance()").checked_write(_delegateLeftover);

        // Store the dude leftover
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address)").with_key(didPayData.payer).checked_write(
            _dudeLeftover
        );

        uint256 _balanceBeforeSweep = dude.balance;

        // Test: sweep
        vm.prank(dude);
        delegate.sweep(dude);

        uint256 _balanceAfterSweep = dude.balance;
        uint256 _sweptAmount = _balanceAfterSweep - _balanceBeforeSweep;

        // Check: correct overall sweep balance?
        assertEq(delegate.sweepBalance(), _delegateLeftover - _dudeLeftover);

        // Check: correct dude sweep balance
        assertEq(delegate.sweepBalanceOf(dude), 0);

        // Check: correct swept balance
        assertEq(_sweptAmount, _dudeLeftover);
    }

    /**
     * @notice Test sweep revert if transfer fails
     */
    function test_Sweep_revertIfTransferFails() public {
        // Store the delegate leftover
        stdstore.target(address(delegate)).sig("sweepBalance()").checked_write(1 ether);

        // Store the dude leftover
        stdstore.target(address(delegate)).sig("sweepBalanceOf(address)").with_key(didPayData.payer).checked_write(
            1 ether
        );

        // Deal enough ETH
        vm.deal(address(delegate), 1 ether);

        // no fallback -> will revert
        vm.etch(dude, "6969");

        // Check: revert?
        vm.prank(dude);
        vm.expectRevert(abi.encodeWithSelector(JBBuybackDelegate.JuiceBuyback_TransferFailed.selector));
        delegate.sweep(dude);
    }

    /**
     * @notice Test increase seconds ago
     */
    function test_increaseSecondsAgo(uint256 _oldValue, uint256 _newValue) public {
        // Avoid overflow in second bound
        _oldValue = bound(_oldValue, 0, type(uint32).max - 1);

        // Store a preexisting secondsAgo (packed slot, need a setter instead of stdstore)
        delegate.ForTest_setSecondsAgo(uint32(_oldValue));

        // Only increase accepted
        _newValue = bound(_newValue, delegate.secondsAgo() + 1, type(uint32).max);

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_SecondsAgoIncrease(delegate.secondsAgo(), _newValue);

        // Test: change seconds ago
        vm.prank(owner);
        delegate.increaseSecondsAgo(uint32(_newValue));

        // Check: correct seconds ago?
        assertEq(delegate.secondsAgo(), _newValue);
    }

    /**
     * @notice Test increase seconds ago revert if no increase
     */
    function test_increaseSecondsAgo_revertIfNoIncrease(uint256 _oldValue, uint256 _newValue) public {
        // Avoid overflow in second bound
        _oldValue = bound(_oldValue, 0, type(uint32).max - 1);

        // Store a preexisting secondsAgo
        delegate.ForTest_setSecondsAgo(uint32(_oldValue));

        // Not an increase
        _newValue = bound(_newValue, 0, delegate.secondsAgo());

        // check: revert?
        vm.expectRevert(abi.encodeWithSelector(JBBuybackDelegate.JuiceBuyback_NewSecondsAgoTooLow.selector));

        // Test: change seconds ago
        vm.prank(owner);
        delegate.increaseSecondsAgo(uint32(_newValue));
    }

    /**
     * @notice Test increase seconds ago revert if wrong caller
     */
    function test_increaseSecondsAgo_revertIfWrongCaller(address _notOwner) public {
        vm.assume(owner != _notOwner);

        emit log_address(owner);
        emit log_address(_notOwner);
        emit log_address(delegate.owner());

        // check: revert?
        vm.expectRevert("Ownable: caller is not the owner");

        // Test: change seconds ago (left uninit/at 0)
        vm.startPrank(_notOwner);
        delegate.increaseSecondsAgo(999);
    }

    /**
     * @notice Test set twap delta
     */
    function test_setTwapDelta(uint256 _oldDelta, uint256 _newDelta) public {
        // Store a preexisting twap delta
        stdstore.target(address(delegate)).sig("twapDelta()").checked_write(_oldDelta);

        // Check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_TwapDeltaChanged(_oldDelta, _newDelta);

        // Test: set the twap
        vm.prank(owner);
        delegate.setTwapDelta(_newDelta);

        // Check: correct twap?
        assertEq(delegate.twapDelta(), _newDelta);
    }

    /**
     * @notice Test set twap delta reverts if wrong caller
     */
    function test_setTwapDelta_revertWrongCaller(address _notOwner) public {
        vm.assume(owner != _notOwner);

        // check: revert?
        vm.expectRevert("Ownable: caller is not the owner");

        // Test: set the twap
        vm.prank(_notOwner);
        delegate.setTwapDelta(1);
    }
}

contract ForTest_BuybackDelegate is JBBuybackDelegate {
    constructor(
        IERC20 _projectToken,
        IWETH9 _weth,
        address _factory,
        uint24 _fee,
        uint32 _secondsAgo,
        uint256 _twapDelta,
        IJBDirectory _directory,
        IJBController3_1 _controller,
        bytes4 _id
    ) JBBuybackDelegate(_projectToken, _weth, _factory, _fee, _secondsAgo, _twapDelta, _directory, _controller, _id) {}

    function ForTest_getQuote(uint256 _amountIn) external view returns (uint256 _amountOut) {
        return _getQuote(_amountIn);
    }

    function ForTest_setSecondsAgo(uint32 _secondsAgo) external {
        secondsAgo = _secondsAgo;
    }
}
