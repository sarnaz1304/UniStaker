// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.23;

import {Test, console2} from "forge-std/Test.sol";
import {V3FactoryOwner} from "src/V3FactoryOwner.sol";
import {INotifiableRewardReceiver} from "src/interfaces/INotifiableRewardReceiver.sol";
import {IUniswapV3PoolOwnerActions} from "src/interfaces/IUniswapV3PoolOwnerActions.sol";
import {ERC20Fake} from "test/fakes/ERC20Fake.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC20Errors} from "openzeppelin/interfaces/draft-IERC6093.sol";
import {MockRewardReceiver} from "test/mocks/MockRewardReceiver.sol";
import {MockUniswapV3Pool} from "test/mocks/MockUniswapV3Pool.sol";

contract V3FactoryOwnerTest is Test {
  V3FactoryOwner factoryOwner;
  address admin = makeAddr("Admin");
  ERC20Fake payoutToken;
  MockRewardReceiver rewardReceiver;
  MockUniswapV3Pool pool;

  event AdminUpdated(address indexed oldAmin, address indexed newAdmin);
  event FeesClaimed(
    address indexed pool,
    address indexed caller,
    address indexed recipient,
    uint256 amount0,
    uint256 amount1
  );

  function setUp() public {
    vm.label(admin, "Admin");

    payoutToken = new ERC20Fake();
    vm.label(address(payoutToken), "Payout Token");

    rewardReceiver = new MockRewardReceiver();
    vm.label(address(rewardReceiver), "Reward Receiver");

    pool = new MockUniswapV3Pool();
    vm.label(address(pool), "Pool");
  }

  // In order to fuzz over the payout amount, we require each test to call this method to deploy
  // the factory owner before doing anything else.
  function _deployFactoryOwnerWithPayoutAmount(uint256 _payoutAmount) public {
    factoryOwner = new V3FactoryOwner(admin, payoutToken, _payoutAmount, rewardReceiver);
    vm.label(address(factoryOwner), "Factory Owner");
  }
}

contract Constructor is V3FactoryOwnerTest {
  function testFuzz_SetsTheAdminPayoutTokenAndPayoutAmount(uint256 _payoutAmount) public {
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    assertEq(factoryOwner.admin(), admin);
    assertEq(address(factoryOwner.PAYOUT_TOKEN()), address(payoutToken));
    assertEq(factoryOwner.PAYOUT_AMOUNT(), _payoutAmount);
    assertEq(address(factoryOwner.REWARD_RECEIVER()), address(rewardReceiver));
  }

  function testFuzz_SetsAllParametersToArbitraryValues(
    address _admin,
    address _payoutToken,
    uint256 _payoutAmount,
    address _rewardReceiver
  ) public {
    vm.assume(_admin != address(0));
    V3FactoryOwner _factoryOwner = new V3FactoryOwner(
      _admin, IERC20(_payoutToken), _payoutAmount, INotifiableRewardReceiver(_rewardReceiver)
    );
    assertEq(_factoryOwner.admin(), _admin);
    assertEq(address(_factoryOwner.PAYOUT_TOKEN()), address(_payoutToken));
    assertEq(_factoryOwner.PAYOUT_AMOUNT(), _payoutAmount);
    assertEq(address(_factoryOwner.REWARD_RECEIVER()), _rewardReceiver);
  }

  function testFuzz_RevertIf_TheAdminIsAddressZero(
    address _payoutToken,
    uint256 _payoutAmount,
    address _rewardReceiver
  ) public {
    vm.expectRevert(V3FactoryOwner.V3FactoryOwner__InvalidAddress.selector);
    new V3FactoryOwner(
      address(0), IERC20(_payoutToken), _payoutAmount, INotifiableRewardReceiver(_rewardReceiver)
    );
  }
}

contract SetAdmin is V3FactoryOwnerTest {
  function testFuzz_UpdatesTheAdminWhenCalledByTheCurrentAdmin(address _newAdmin) public {
    vm.assume(_newAdmin != address(0));
    _deployFactoryOwnerWithPayoutAmount(0);

    vm.prank(admin);
    factoryOwner.setAdmin(_newAdmin);

    assertEq(factoryOwner.admin(), _newAdmin);
  }

  function testFuzz_EmitsAnEventWhenUpdatingTheAdmin(address _newAdmin) public {
    vm.assume(_newAdmin != address(0));
    _deployFactoryOwnerWithPayoutAmount(0);

    vm.expectEmit(true, true, true, true);
    vm.prank(admin);
    emit AdminUpdated(admin, _newAdmin);
    factoryOwner.setAdmin(_newAdmin);
  }

  function testFuzz_RevertIf_TheCallerIsNotTheCurrentAdmin(address _notAdmin, address _newAdmin)
    public
  {
    _deployFactoryOwnerWithPayoutAmount(0);

    vm.assume(_notAdmin != admin);

    vm.expectRevert(V3FactoryOwner.V3FactoryOwner__Unauthorized.selector);
    vm.prank(_notAdmin);
    factoryOwner.setAdmin(_newAdmin);
  }

  function test_RevertIf_TheNewAdminIsAddressZero() public {
    _deployFactoryOwnerWithPayoutAmount(0);

    vm.expectRevert(V3FactoryOwner.V3FactoryOwner__InvalidAddress.selector);
    vm.prank(admin);
    factoryOwner.setAdmin(address(0));
  }
}

contract ClaimFees is V3FactoryOwnerTest {
  function testFuzz_TransfersThePayoutFromTheCallerToTheRewardReceiver(
    uint256 _payoutAmount,
    address _caller,
    address _recipient,
    uint128 _amount0,
    uint128 _amount1
  ) public {
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    vm.assume(_caller != address(0) && _recipient != address(0));
    payoutToken.mint(_caller, _payoutAmount);

    vm.startPrank(_caller);
    payoutToken.approve(address(factoryOwner), _payoutAmount);
    factoryOwner.claimFees(pool, _recipient, _amount0, _amount1);
    vm.stopPrank();

    assertEq(payoutToken.balanceOf(address(rewardReceiver)), _payoutAmount);
  }

  function testFuzz_NotifiesTheRewardReceiverOfTheReward(
    uint256 _payoutAmount,
    address _caller,
    address _recipient,
    uint128 _amount0,
    uint128 _amount1
  ) public {
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    vm.assume(_caller != address(0) && _recipient != address(0));
    payoutToken.mint(_caller, _payoutAmount);

    vm.startPrank(_caller);
    payoutToken.approve(address(factoryOwner), _payoutAmount);
    factoryOwner.claimFees(pool, _recipient, _amount0, _amount1);
    vm.stopPrank();

    assertEq(rewardReceiver.lastParam__notifyRewardsAmount_amount(), _payoutAmount);
  }

  function testFuzz_CallsPoolCollectProtocolMethodWithRecipientAndAmountsRequested(
    uint256 _payoutAmount,
    address _caller,
    address _recipient,
    uint128 _amount0,
    uint128 _amount1
  ) public {
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    vm.assume(_caller != address(0) && _recipient != address(0));
    payoutToken.mint(_caller, _payoutAmount);

    vm.startPrank(_caller);
    payoutToken.approve(address(factoryOwner), _payoutAmount);
    factoryOwner.claimFees(pool, _recipient, _amount0, _amount1);
    vm.stopPrank();

    assertEq(pool.lastParam__collectProtocol_recipient(), _recipient);
    assertEq(pool.lastParam__collectProtocol_amount0Requested(), _amount0);
    assertEq(pool.lastParam__collectProtocol_amount1Requested(), _amount1);
  }

  function testFuzz_EmitsAnEventWithFeeClaimParameters(
    uint256 _payoutAmount,
    address _caller,
    address _recipient,
    uint128 _amount0,
    uint128 _amount1
  ) public {
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    vm.assume(_caller != address(0) && _recipient != address(0));
    payoutToken.mint(_caller, _payoutAmount);

    vm.startPrank(_caller);
    payoutToken.approve(address(factoryOwner), _payoutAmount);
    vm.expectEmit(true, true, true, true);
    emit FeesClaimed(address(pool), _caller, _recipient, _amount0, _amount1);
    factoryOwner.claimFees(pool, _recipient, _amount0, _amount1);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerHasInsufficientBalanceOfPayoutToken(
    uint256 _payoutAmount,
    address _caller,
    address _recipient,
    uint128 _amount0,
    uint128 _amount1,
    uint256 _mintAmount
  ) public {
    _payoutAmount = bound(_payoutAmount, 1, type(uint256).max);
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    vm.assume(_caller != address(0) && _recipient != address(0));
    _mintAmount = bound(_mintAmount, 0, _payoutAmount - 1);
    payoutToken.mint(_caller, _mintAmount);

    vm.startPrank(_caller);
    payoutToken.approve(address(factoryOwner), _payoutAmount);

    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientBalance.selector, _caller, _mintAmount, _payoutAmount
      )
    );
    factoryOwner.claimFees(pool, _recipient, _amount0, _amount1);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_CallerHasInsufficientApprovalForPayoutToken(
    uint256 _payoutAmount,
    address _caller,
    address _recipient,
    uint128 _amount0,
    uint128 _amount1,
    uint256 _approveAmount
  ) public {
    _payoutAmount = bound(_payoutAmount, 1, type(uint256).max);
    _deployFactoryOwnerWithPayoutAmount(_payoutAmount);

    vm.assume(_caller != address(0) && _recipient != address(0));
    _approveAmount = bound(_approveAmount, 0, _payoutAmount - 1);
    payoutToken.mint(_caller, _payoutAmount);

    vm.startPrank(_caller);
    payoutToken.approve(address(factoryOwner), _approveAmount);

    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(factoryOwner),
        _approveAmount,
        _payoutAmount
      )
    );
    factoryOwner.claimFees(pool, _recipient, _amount0, _amount1);
    vm.stopPrank();
  }
}