// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {ConditionalGrants} from 'src/contracts/ConditionalGrants.sol';
import {IConditionalGrants} from 'src/interfaces/IConditionalGrants.sol';

/**
 * @notice Fork tests for {ConditionalGrants} escrowing into Aave v3 on Celo mainnet, through Aave's
 *         ERC-4626 wrapper for USDT (waCelUSDT). Aave interest accrues from block.timestamp, so
 *         warping time grows the escrow without any other transactions.
 * @dev Opt-in: run with CELO_FORK_TESTS=true (yarn test:fork). Addresses are from bgd-labs'
 *      aave-address-book (AaveV3Celo) and were checked on-chain: waCelUSDT.asset() is USDT.
 */
contract ConditionalGrantsAaveCeloFork is Test {
  uint256 internal constant _FORK_BLOCK = 80_533_147;
  IERC20 internal constant _USDT = IERC20(0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e);
  IERC4626 internal constant _WA_USDT = IERC4626(0x5264B1F45616dB619Bb3c8DCeBD86fB33FA0e53F);

  uint256 internal constant _ADVANCE = 1000e6;
  uint256 internal constant _GRANT = 1000e6;
  uint256 internal constant _PERIOD = 300 days;
  uint256 internal constant _START_BAL = 10_000e6;

  ConditionalGrants public grants;
  address public owner = makeAddr('owner');
  address public bread = makeAddr('bread');
  address public coop = makeAddr('coop');

  function setUp() public {
    if (!vm.envOr('CELO_FORK_TESTS', false)) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(vm.rpcUrl('celo'), _FORK_BLOCK);

    vm.startPrank(owner);
    grants = ConditionalGrants(
      address(
        new TransparentUpgradeableProxy(
          address(new ConditionalGrants()),
          address(new ProxyAdmin(owner)),
          abi.encodeWithSelector(ConditionalGrants.initialize.selector, owner)
        )
      )
    );
    grants.setTokenAllowed(address(_USDT), true);
    grants.setVaultAllowed(address(_WA_USDT), true);
    vm.stopPrank();

    address[2] memory holders = [bread, coop];
    for (uint256 i = 0; i < holders.length; i++) {
      deal(address(_USDT), holders[i], _START_BAL);
      vm.prank(holders[i]);
      _USDT.approve(address(grants), type(uint256).max);
    }
  }

  function _create(address _grantee) internal returns (uint256 _id) {
    vm.prank(bread);
    _id = grants.create(
      IConditionalGrants.GrantTerms({
        token: address(_USDT),
        vault: address(_WA_USDT),
        advance: _ADVANCE,
        grant: _GRANT,
        acceptBy: block.timestamp + 14 days,
        payBackPeriod: _PERIOD,
        termsHash: bytes32(0)
      }),
      _grantee
    );
  }

  function _status(uint256 _id) internal view returns (IConditionalGrants.GrantStatus memory _st) {
    (, _st) = grants.getGrant(_id);
  }

  /// @dev Every share the contract holds must belong to some grant's escrow.
  function _assertSharesMatch(uint256[] memory _ids) internal view {
    uint256 _sum;
    for (uint256 i = 0; i < _ids.length; i++) {
      _sum += _status(_ids[i]).held;
    }
    assertEq(_WA_USDT.balanceOf(address(grants)), _sum, 'contract shares == sum of per-grant shares');
  }

  function test_fork_escrowDepositsIntoAave() public {
    uint256 _id = _create(coop);
    assertGt(_status(_id).held, 0, 'holds waCelUSDT shares');
    // Rounding on deposit can cost at most a unit
    assertApproxEqAbs(grants.escrowValue(_id), _ADVANCE + _GRANT, 1, 'escrow worth what was deposited');
    assertEq(_USDT.balanceOf(address(grants)), 0, 'no idle USDT');
  }

  function test_fork_waitingGrantEarnsYieldForGrantor() public {
    uint256 _id = _create(coop);
    vm.prank(coop);
    grants.accept(_id, bytes32(0));
    assertEq(_status(_id).disbursed, _ADVANCE, 'grantee received the full advance');
    assertEq(_USDT.balanceOf(coop), _START_BAL + _ADVANCE);

    uint256 _escrowAtAccept = grants.escrowValue(_id);
    vm.warp(block.timestamp + 180 days);
    uint256 _escrowLater = grants.escrowValue(_id);
    assertGt(_escrowLater, _escrowAtAccept, 'waiting grant grew in Aave');
    emit log_named_decimal_uint('grant escrow after 180 days', _escrowLater, 6);

    vm.prank(coop);
    grants.payBack(_id, _ADVANCE);
    grants.releaseGrant(_id);

    // The grantee gets exactly the grant; everything the escrow earned goes to the grantor.
    assertEq(_USDT.balanceOf(coop), _START_BAL + _GRANT, 'grantee: advance repaid, grant received');
    uint256 _owed = _status(_id).grantorOwed;
    assertGt(_owed, _ADVANCE, 'grantor credit = payments + yield');
    emit log_named_decimal_uint('yield credited to grantor', _owed - _ADVANCE, 6);

    grants.collect(_id);
    assertEq(_USDT.balanceOf(bread), _START_BAL - _GRANT + (_owed - _ADVANCE), 'grantor net cost = grant - yield');
    assertEq(_status(_id).held, 0, 'escrow empty');
    assertEq(_WA_USDT.balanceOf(address(grants)), 0, 'no shares left behind');
    assertEq(_USDT.balanceOf(address(grants)), 0, 'no USDT left behind');
  }

  function test_fork_cancelRefundsEscrowWithYield() public {
    uint256 _id = _create(coop);
    vm.warp(block.timestamp + 13 days);
    vm.prank(bread);
    grants.cancel(_id);
    assertGt(_USDT.balanceOf(bread), _START_BAL, 'refund includes yield from the open offer');
    emit log_named_decimal_uint('yield on a 13-day open offer', _USDT.balanceOf(bread) - _START_BAL, 6);
    assertEq(_WA_USDT.balanceOf(address(grants)), 0);
  }

  function test_fork_reclaimAfterDefaultReturnsGrantWithYield() public {
    uint256 _id = _create(coop);
    vm.prank(coop);
    grants.accept(_id, bytes32(0));
    vm.prank(coop);
    grants.payBack(_id, 400e6);

    vm.warp(grants.reclaimableAt(_id));
    uint256 _before = _USDT.balanceOf(bread);
    vm.prank(bread);
    grants.reclaimGrant(_id);
    uint256 _reclaimed = _USDT.balanceOf(bread) - _before;
    assertGt(_reclaimed, _GRANT, 'reclaim returns the grant plus its yield');
    emit log_named_decimal_uint('reclaimed (grant + yield)', _reclaimed, 6);
    assertEq(grants.outstanding(_id), _ADVANCE - 400e6, 'grantee still owes the rest');
    assertEq(_WA_USDT.balanceOf(address(grants)), 0);
  }

  function test_fork_twoGrantsShareTheVaultWithoutBleed() public {
    uint256[] memory _ids = new uint256[](2);
    _ids[0] = _create(coop);
    vm.warp(block.timestamp + 30 days);
    _ids[1] = _create(coop);
    _assertSharesMatch(_ids);

    // The older grant has earned more; the newer one only what it was deposited with.
    assertGt(grants.escrowValue(_ids[0]), grants.escrowValue(_ids[1]), 'older escrow earned more');
    assertApproxEqAbs(grants.escrowValue(_ids[1]), _ADVANCE + _GRANT, 1);

    vm.startPrank(bread);
    grants.cancel(_ids[1]);
    _assertSharesMatch(_ids);
    grants.cancel(_ids[0]);
    vm.stopPrank();
    _assertSharesMatch(_ids);
    assertEq(_WA_USDT.balanceOf(address(grants)), 0);
  }
}
