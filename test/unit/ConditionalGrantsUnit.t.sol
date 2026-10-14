// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

import {ConditionalGrants} from 'src/contracts/ConditionalGrants.sol';
import {IConditionalGrants} from 'src/interfaces/IConditionalGrants.sol';
import {MockERC20} from 'test/mocks/MockERC20.sol';
import {MockERC4626} from 'test/mocks/MockERC4626.sol';

/// @dev 6-decimal token so the tests exercise the same units as USDT on Celo.
contract MockUSDT is MockERC20 {
  constructor() MockERC20('Tether USD', 'USDT') {}

  function decimals() public pure override returns (uint8) {
    return 6;
  }
}

/**
 * @notice Unit tests for {ConditionalGrants}.
 * @dev Actors: owner is the registry admin, bread is the grantor, coop is the grantee (the
 *      nonprofit), helper pays back on the grantee's behalf, stranger has no role.
 */
contract ConditionalGrantsUnit is Test {
  ConditionalGrants public grants;
  MockUSDT public usdt;
  MockERC4626 public vault;

  uint256 public constant ADVANCE = 1000e6;
  uint256 public constant GRANT = 1000e6;
  uint256 public constant ACCEPT_WINDOW = 14 days;
  uint256 public constant PERIOD = 300 days;
  uint256 public constant START_BAL = 100_000e6;
  bytes32 public constant TERMS = keccak256('ipfs://grant-agreement');

  address public owner = makeAddr('owner');
  address public bread = makeAddr('bread');
  address public coop = makeAddr('coop');
  address public helper = makeAddr('helper');
  address public stranger = makeAddr('stranger');

  function setUp() public {
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
    usdt = new MockUSDT();
    vault = new MockERC4626(IERC20(address(usdt)));
    grants.setTokenAllowed(address(usdt), true);
    grants.setVaultAllowed(address(vault), true);
    vm.stopPrank();

    address[4] memory holders = [bread, coop, helper, stranger];
    for (uint256 i = 0; i < holders.length; i++) {
      usdt.mint(holders[i], START_BAL);
      vm.prank(holders[i]);
      usdt.approve(address(grants), type(uint256).max);
    }
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  function _terms(address _vault, uint256 _grant) internal view returns (IConditionalGrants.GrantTerms memory) {
    return IConditionalGrants.GrantTerms({
      token: address(usdt),
      vault: _vault,
      advance: ADVANCE,
      grant: _grant,
      acceptBy: block.timestamp + ACCEPT_WINDOW,
      payBackPeriod: PERIOD,
      termsHash: TERMS
    });
  }

  function _create(address _vault, uint256 _grant) internal returns (uint256 _id) {
    vm.prank(bread);
    _id = grants.create(_terms(_vault, _grant), coop);
  }

  function _createAccepted(address _vault, uint256 _grant) internal returns (uint256 _id) {
    _id = _create(_vault, _grant);
    vm.prank(coop);
    grants.accept(_id, TERMS);
  }

  function _status(uint256 _id) internal view returns (IConditionalGrants.GrantStatus memory _st) {
    (, _st) = grants.getGrant(_id);
  }

  // --------------------------------------------------------------------------
  // Admin
  // --------------------------------------------------------------------------

  function test_initialize_cannotReinitialize() public {
    vm.expectRevert();
    grants.initialize(stranger);
  }

  function test_setTokenAllowed_onlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
    grants.setTokenAllowed(address(usdt), false);
  }

  function test_setVaultAllowed_onlyOwner() public {
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger));
    grants.setVaultAllowed(address(vault), false);
  }

  function test_allowlists_emitAndToggle() public {
    vm.startPrank(owner);
    vm.expectEmit(true, true, false, false);
    emit IConditionalGrants.TokenAllowed(address(usdt), false);
    grants.setTokenAllowed(address(usdt), false);
    vm.expectEmit(true, true, false, false);
    emit IConditionalGrants.VaultAllowed(address(vault), false);
    grants.setVaultAllowed(address(vault), false);
    vm.stopPrank();
    assertFalse(grants.isTokenAllowed(address(usdt)));
    assertFalse(grants.isVaultAllowed(address(vault)));
  }

  // --------------------------------------------------------------------------
  // create
  // --------------------------------------------------------------------------

  function test_create_pullsAdvancePlusGrant() public {
    uint256 _id = _create(address(0), GRANT);
    assertEq(_id, 0);
    assertEq(grants.nextId(), 1);
    assertEq(usdt.balanceOf(bread), START_BAL - ADVANCE - GRANT);
    assertEq(usdt.balanceOf(address(grants)), ADVANCE + GRANT);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Offered));
    assertEq(grants.escrowValue(_id), ADVANCE + GRANT);
    assertEq(grants.getGrantorGrants(bread)[0], _id);
    assertEq(grants.getGranteeGrants(coop)[0], _id);
    IConditionalGrants.GrantStatus memory _st = _status(_id);
    assertEq(_st.grantor, bread);
    assertEq(_st.grantee, coop);
  }

  function test_create_depositsIntoVault() public {
    uint256 _id = _create(address(vault), GRANT);
    assertEq(usdt.balanceOf(address(grants)), 0);
    assertEq(vault.balanceOf(address(grants)), _status(_id).held);
    assertEq(grants.escrowValue(_id), ADVANCE + GRANT);
  }

  function test_create_emits() public {
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    vm.expectEmit(true, true, true, true);
    emit IConditionalGrants.GrantCreated(0, bread, coop, _t);
    vm.prank(bread);
    grants.create(_t, coop);
  }

  function test_create_revertsTokenNotAllowed() public {
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    _t.token = address(0xdead);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.TokenNotAllowed.selector);
    grants.create(_t, coop);
  }

  function test_create_revertsVaultNotAllowed() public {
    vm.prank(owner);
    grants.setVaultAllowed(address(vault), false);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidVault.selector);
    grants.create(_terms(address(vault), GRANT), coop);
  }

  function test_create_revertsVaultAssetMismatch() public {
    MockERC20 _other = new MockERC20('Other', 'OTH');
    MockERC4626 _otherVault = new MockERC4626(IERC20(address(_other)));
    vm.prank(owner);
    grants.setVaultAllowed(address(_otherVault), true);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidVault.selector);
    grants.create(_terms(address(_otherVault), GRANT), coop);
  }

  function test_create_revertsZeroAdvance() public {
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    _t.advance = 0;
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidAdvance.selector);
    grants.create(_t, coop);
  }

  function test_create_revertsAcceptByNotInFuture() public {
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    _t.acceptBy = block.timestamp;
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidAcceptBy.selector);
    grants.create(_t, coop);
  }

  function test_create_revertsZeroPeriod() public {
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    _t.payBackPeriod = 0;
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidPayBackPeriod.selector);
    grants.create(_t, coop);
  }

  function test_create_revertsPeriodAboveMax() public {
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    _t.payBackPeriod = grants.MAX_PAY_BACK_PERIOD() + 1;
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidPayBackPeriod.selector);
    grants.create(_t, coop);

    _t.payBackPeriod = grants.MAX_PAY_BACK_PERIOD();
    vm.prank(bread);
    grants.create(_t, coop);
  }

  function test_create_revertsSelfGrantee() public {
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidGrantee.selector);
    grants.create(_terms(address(0), GRANT), bread);
  }

  // --------------------------------------------------------------------------
  // setGrantee
  // --------------------------------------------------------------------------

  function test_setGrantee_namesGranteeLater() public {
    vm.prank(bread);
    uint256 _id = grants.create(_terms(address(0), GRANT), address(0));
    assertEq(grants.getGranteeGrants(coop).length, 0);

    vm.expectEmit(true, true, false, false);
    emit IConditionalGrants.GranteeSet(_id, coop);
    vm.prank(bread);
    grants.setGrantee(_id, coop);

    assertEq(_status(_id).grantee, coop);
    assertEq(grants.getGranteeGrants(coop)[0], _id);
    vm.prank(coop);
    grants.accept(_id, TERMS);
  }

  function test_setGrantee_reverts() public {
    vm.prank(bread);
    uint256 _id = grants.create(_terms(address(0), GRANT), address(0));

    vm.prank(stranger);
    vm.expectRevert(IConditionalGrants.NotGrantor.selector);
    grants.setGrantee(_id, coop);

    vm.startPrank(bread);
    vm.expectRevert(IConditionalGrants.InvalidGrantee.selector);
    grants.setGrantee(_id, address(0));
    vm.expectRevert(IConditionalGrants.InvalidGrantee.selector);
    grants.setGrantee(_id, bread);
    grants.setGrantee(_id, coop);
    vm.expectRevert(IConditionalGrants.GranteeAlreadySet.selector);
    grants.setGrantee(_id, helper);
    vm.stopPrank();

    vm.expectRevert(IConditionalGrants.GrantNotFound.selector);
    grants.setGrantee(99, coop);
  }

  function test_setGrantee_revertsAfterExpiry() public {
    vm.prank(bread);
    uint256 _id = grants.create(_terms(address(0), GRANT), address(0));
    vm.warp(block.timestamp + ACCEPT_WINDOW);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.setGrantee(_id, coop);
  }

  // --------------------------------------------------------------------------
  // cancel
  // --------------------------------------------------------------------------

  function test_cancel_refundsOffered() public {
    uint256 _id = _create(address(0), GRANT);
    vm.expectEmit(true, false, false, true);
    emit IConditionalGrants.GrantCancelled(_id, ADVANCE + GRANT);
    vm.prank(bread);
    grants.cancel(_id);
    assertEq(usdt.balanceOf(bread), START_BAL);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Cancelled));
  }

  function test_cancel_refundsExpiredWithYield() public {
    uint256 _id = _create(address(vault), GRANT);
    vault.simulateYield(10e6);
    vm.warp(block.timestamp + ACCEPT_WINDOW);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Expired));
    vm.prank(bread);
    grants.cancel(_id);
    assertApproxEqAbs(usdt.balanceOf(bread), START_BAL + 10e6, 1);
    assertEq(vault.balanceOf(address(grants)), 0);
  }

  function test_cancel_reverts() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(stranger);
    vm.expectRevert(IConditionalGrants.NotGrantor.selector);
    grants.cancel(_id);

    vm.prank(coop);
    grants.accept(_id, TERMS);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.cancel(_id);
  }

  // --------------------------------------------------------------------------
  // accept
  // --------------------------------------------------------------------------

  function test_accept_disbursesAdvance() public {
    uint256 _id = _create(address(0), GRANT);
    vm.expectEmit(true, true, false, true);
    emit IConditionalGrants.GrantAccepted(_id, coop, ADVANCE, block.timestamp + PERIOD);
    vm.prank(coop);
    grants.accept(_id, TERMS);

    assertEq(usdt.balanceOf(coop), START_BAL + ADVANCE);
    assertEq(grants.escrowValue(_id), GRANT);
    assertEq(grants.outstanding(_id), ADVANCE);
    IConditionalGrants.GrantStatus memory _st = _status(_id);
    assertEq(_st.acceptedAt, block.timestamp);
    assertEq(_st.payBackBy, block.timestamp + PERIOD);
    assertEq(_st.disbursed, ADVANCE);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Active));
  }

  function test_accept_fromVaultKeepsGrantEarning() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    assertEq(usdt.balanceOf(coop), START_BAL + ADVANCE);
    assertApproxEqAbs(grants.escrowValue(_id), GRANT, 1);
    vault.simulateYield(50e6);
    assertGt(grants.escrowValue(_id), GRANT);
  }

  function test_accept_noGrantCreditsOfferYieldToGrantor() public {
    uint256 _id = _create(address(vault), 0);
    vault.simulateYield(5e6);
    vm.prank(coop);
    grants.accept(_id, TERMS);
    assertEq(usdt.balanceOf(coop), START_BAL + ADVANCE);
    assertEq(_status(_id).held, 0);
    assertApproxEqAbs(_status(_id).grantorOwed, 5e6, 1);
  }

  function test_accept_reverts() public {
    uint256 _id = _create(address(0), GRANT);

    vm.prank(stranger);
    vm.expectRevert(IConditionalGrants.NotGrantee.selector);
    grants.accept(_id, TERMS);

    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.TermsMismatch.selector);
    grants.accept(_id, bytes32(0));

    vm.expectRevert(IConditionalGrants.GrantNotFound.selector);
    grants.accept(99, TERMS);

    vm.warp(block.timestamp + ACCEPT_WINDOW);
    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.accept(_id, TERMS);
  }

  function test_accept_revertsTwice() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.accept(_id, TERMS);
  }

  function test_accept_revertsWhenCancelled() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(bread);
    grants.cancel(_id);
    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.accept(_id, TERMS);
  }

  // --------------------------------------------------------------------------
  // payBack
  // --------------------------------------------------------------------------

  function test_payBack_installmentsUnlockGrant() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    for (uint256 i = 0; i < 9; i++) {
      vm.prank(coop);
      grants.payBack(_id, 100e6);
    }
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Active));
    assertEq(grants.outstanding(_id), 100e6);

    vm.expectEmit(true, true, false, true);
    emit IConditionalGrants.AdvancePaidBack(_id, coop, 100e6, ADVANCE);
    vm.prank(coop);
    grants.payBack(_id, 100e6);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.PaidBack));
    assertEq(_status(_id).grantorOwed, ADVANCE);
  }

  function test_payBack_capsAtOutstanding() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    grants.payBack(_id, 5000e6);
    assertEq(_status(_id).paidBack, ADVANCE);
    assertEq(usdt.balanceOf(coop), START_BAL);
  }

  function test_payBack_byHelper() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(helper);
    grants.payBack(_id, ADVANCE);
    assertEq(usdt.balanceOf(helper), START_BAL - ADVANCE);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.PaidBack));
  }

  function test_payBack_reverts() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.payBack(_id, 1);

    vm.prank(coop);
    grants.accept(_id, TERMS);
    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.InvalidAmount.selector);
    grants.payBack(_id, 0);

    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    vm.prank(coop);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.payBack(_id, 1);

    vm.expectRevert(IConditionalGrants.GrantNotFound.selector);
    grants.payBack(99, 1);
  }

  function test_payBack_lateStillUnlocksIfNotReclaimed() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.warp(block.timestamp + PERIOD + 30 days);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Overdue));
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    grants.releaseGrant(_id);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
  }

  // --------------------------------------------------------------------------
  // releaseGrant
  // --------------------------------------------------------------------------

  function test_releaseGrant_paysGranteePermissionlessly() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);

    vm.expectEmit(true, true, false, true);
    emit IConditionalGrants.GrantReleased(_id, coop, GRANT);
    vm.prank(stranger);
    grants.releaseGrant(_id);

    assertEq(usdt.balanceOf(coop), START_BAL + GRANT);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
    assertEq(grants.escrowValue(_id), 0);
  }

  function test_releaseGrant_yieldGoesToGrantor() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    vault.simulateYield(40e6);
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    grants.releaseGrant(_id);

    assertEq(usdt.balanceOf(coop), START_BAL + GRANT);
    uint256 _owed = _status(_id).grantorOwed;
    assertApproxEqAbs(_owed, ADVANCE + 40e6, 2);
    grants.collect(_id);
    assertApproxEqAbs(usdt.balanceOf(bread), START_BAL - ADVANCE - GRANT + ADVANCE + 40e6, 2);
    assertEq(vault.balanceOf(address(grants)), 0);
  }

  function test_releaseGrant_reverts() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.releaseGrant(_id);

    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    grants.releaseGrant(_id);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.releaseGrant(_id);
  }

  function test_noGrant_completesOnPayBack() public {
    uint256 _id = _createAccepted(address(0), 0);
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.releaseGrant(_id);
  }

  // --------------------------------------------------------------------------
  // reclaimGrant / extendPayBackBy
  // --------------------------------------------------------------------------

  function test_reclaimGrant_whenOverdue() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    vm.prank(coop);
    grants.payBack(_id, 400e6);
    vault.simulateYield(20e6);
    vm.warp(block.timestamp + PERIOD + grants.RECLAIM_GRACE_PERIOD());

    vm.prank(bread);
    grants.reclaimGrant(_id);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Defaulted));
    assertApproxEqAbs(usdt.balanceOf(bread), START_BAL - ADVANCE - GRANT + GRANT + 20e6, 2);

    // The advance is still owed and can be paid back after default, but the grant is gone.
    vm.prank(coop);
    grants.payBack(_id, 600e6);
    assertEq(grants.outstanding(_id), 0);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Defaulted));
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.releaseGrant(_id);
    grants.collect(_id);
  }

  function test_reclaimGrant_reverts() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.reclaimGrant(_id);

    vm.warp(block.timestamp + PERIOD);
    vm.prank(stranger);
    vm.expectRevert(IConditionalGrants.NotGrantor.selector);
    grants.reclaimGrant(_id);

    uint256 _noGrant = _createAccepted(address(0), 0);
    vm.warp(block.timestamp + PERIOD);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.reclaimGrant(_noGrant);
  }

  function test_extendPayBackBy_rescuesOverdueGrant() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    uint256 _payBackBy = _status(_id).payBackBy;
    vm.warp(_payBackBy);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Overdue));

    vm.expectEmit(true, false, false, true);
    emit IConditionalGrants.PayBackByExtended(_id, _payBackBy + 60 days);
    vm.prank(bread);
    grants.extendPayBackBy(_id, _payBackBy + 60 days);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Active));

    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.reclaimGrant(_id);
  }

  function test_extendPayBackBy_reverts() public {
    uint256 _id = _create(address(0), GRANT);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.extendPayBackBy(_id, block.timestamp + 1000 days);

    vm.prank(coop);
    grants.accept(_id, TERMS);
    uint256 _payBackBy = _status(_id).payBackBy;
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidPayBackPeriod.selector);
    grants.extendPayBackBy(_id, _payBackBy);

    vm.prank(stranger);
    vm.expectRevert(IConditionalGrants.NotGrantor.selector);
    grants.extendPayBackBy(_id, _payBackBy + 1);
  }

  function test_reclaimGrant_blockedDuringGrace() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    uint256 _payBackBy = _status(_id).payBackBy;

    vm.warp(_payBackBy);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Overdue));
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.ReclaimTooEarly.selector);
    grants.reclaimGrant(_id);

    vm.warp(_payBackBy + grants.RECLAIM_GRACE_PERIOD() - 1);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.ReclaimTooEarly.selector);
    grants.reclaimGrant(_id);

    // Paying back inside the grace period keeps the grant.
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.PaidBack));
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.ReclaimTooEarly.selector);
    grants.reclaimGrant(_id);
    grants.releaseGrant(_id);
    assertEq(usdt.balanceOf(coop), START_BAL + GRANT);
  }

  function test_reclaimGrant_stuckGrantAfterPayBack() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    uint256 _paidBackAt = _status(_id).paidBackAt;
    assertEq(_paidBackAt, block.timestamp);
    assertEq(grants.reclaimableAt(_id), _paidBackAt + grants.STUCK_GRANT_PERIOD());

    vm.warp(_paidBackAt + grants.STUCK_GRANT_PERIOD() - 1);
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.ReclaimTooEarly.selector);
    grants.reclaimGrant(_id);

    vm.warp(_paidBackAt + grants.STUCK_GRANT_PERIOD());
    uint256 _breadBefore = usdt.balanceOf(bread);
    vm.prank(bread);
    grants.reclaimGrant(_id);
    assertEq(usdt.balanceOf(bread), _breadBefore + GRANT);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Defaulted));
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.releaseGrant(_id);
  }

  function test_reclaimableAt_tracksEachPhase() public {
    uint256 _noGrant = _createAccepted(address(0), 0);
    assertEq(grants.reclaimableAt(_noGrant), 0);

    uint256 _id = _create(address(0), GRANT);
    assertEq(grants.reclaimableAt(_id), 0); // not accepted yet
    vm.prank(coop);
    grants.accept(_id, TERMS);
    uint256 _payBackBy = _status(_id).payBackBy;
    assertEq(grants.reclaimableAt(_id), _payBackBy + grants.RECLAIM_GRACE_PERIOD());

    vm.prank(bread);
    grants.extendPayBackBy(_id, _payBackBy + 30 days);
    assertEq(grants.reclaimableAt(_id), _payBackBy + 30 days + grants.RECLAIM_GRACE_PERIOD());

    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    assertEq(grants.reclaimableAt(_id), block.timestamp + grants.STUCK_GRANT_PERIOD());
    grants.releaseGrant(_id);
    assertEq(grants.reclaimableAt(_id), 0);
  }

  function test_extendPayBackBy_revertsIfStillInThePast() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    uint256 _payBackBy = _status(_id).payBackBy;
    vm.warp(_payBackBy + 10 days);

    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidPayBackPeriod.selector);
    grants.extendPayBackBy(_id, _payBackBy + 1 days); // later than before, but already past

    vm.prank(bread);
    grants.extendPayBackBy(_id, block.timestamp + 1 days);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Active));
  }

  // --------------------------------------------------------------------------
  // collect
  // --------------------------------------------------------------------------

  function test_collect_paysGrantor() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    grants.payBack(_id, 300e6);

    vm.expectEmit(true, true, false, true);
    emit IConditionalGrants.GrantorCollected(_id, bread, 300e6);
    vm.prank(stranger);
    grants.collect(_id);
    assertEq(usdt.balanceOf(bread), START_BAL - ADVANCE - GRANT + 300e6);

    vm.expectRevert(IConditionalGrants.NothingToCollect.selector);
    grants.collect(_id);
  }

  // --------------------------------------------------------------------------
  // Vault loss
  // --------------------------------------------------------------------------

  function test_vaultLoss_granteeOwesOnlyWhatWasDisbursed() public {
    uint256 _id = _create(address(vault), GRANT);
    vault.simulateLoss(1500e6);
    vm.prank(coop);
    grants.accept(_id, TERMS);

    uint256 _disbursed = _status(_id).disbursed;
    assertLt(_disbursed, ADVANCE);
    assertEq(grants.outstanding(_id), _disbursed);
    assertEq(_status(_id).held, 0);

    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    assertEq(_status(_id).paidBack, _disbursed);
    grants.releaseGrant(_id);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
  }

  function test_vaultLoss_grantPaysWhatRemains() public {
    uint256 _id = _createAccepted(address(vault), GRANT);
    vault.simulateLoss(250e6);
    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    uint256 _before = usdt.balanceOf(coop);
    grants.releaseGrant(_id);
    assertApproxEqAbs(usdt.balanceOf(coop) - _before, 750e6, 2);
    assertEq(vault.balanceOf(address(grants)), 0);
  }

  // --------------------------------------------------------------------------
  // Isolation and fuzz
  // --------------------------------------------------------------------------

  function test_twoGrantsSameVault_noBleed() public {
    uint256 _a = _createAccepted(address(vault), GRANT);
    uint256 _b = _createAccepted(address(vault), GRANT);
    vault.simulateYield(100e6);
    vm.prank(coop);
    grants.payBack(_a, ADVANCE);
    grants.releaseGrant(_a);

    assertEq(vault.balanceOf(address(grants)), _status(_b).held);
    assertApproxEqAbs(_status(_a).grantorOwed, ADVANCE + 50e6, 2);
    assertApproxEqAbs(grants.escrowValue(_b), GRANT + 50e6, 2);
  }

  function testFuzz_fullLifecycle_conservesFunds(
    uint256 _advance,
    uint256 _grant,
    uint256 _yield,
    uint8 _installments,
    bool _useVault
  ) public {
    _advance = bound(_advance, 1, 10_000e6);
    _grant = bound(_grant, 0, 10_000e6);
    _yield = bound(_yield, 0, 1000e6);
    _installments = uint8(bound(_installments, 1, 24));
    address _v = _useVault ? address(vault) : address(0);

    IConditionalGrants.GrantTerms memory _t = _terms(_v, _grant);
    _t.advance = _advance;
    vm.prank(bread);
    uint256 _id = grants.create(_t, coop);
    vm.prank(coop);
    grants.accept(_id, TERMS);
    // Yield only accrues while the grant sits in escrow; with no grant nothing stays in the vault.
    if (!_useVault || _grant == 0) _yield = 0;
    if (_yield > 0) vault.simulateYield(_yield);

    uint256 _step = _advance / _installments + 1;
    while (grants.outstanding(_id) > 0) {
      vm.prank(coop);
      grants.payBack(_id, _step);
    }
    if (_grant > 0) grants.releaseGrant(_id);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
    if (_status(_id).grantorOwed > 0) grants.collect(_id);

    assertEq(usdt.balanceOf(coop), START_BAL + _grant);
    // The grantor gets back exactly the advance plus at most the simulated yield (part of it can
    // accrue to the vault's virtual shares when the escrow is tiny).
    uint256 _grantorGain = usdt.balanceOf(bread) + _grant - START_BAL;
    assertLe(_grantorGain, _yield);
    assertEq(usdt.balanceOf(address(grants)), 0);
    assertEq(vault.balanceOf(address(grants)), 0);
  }

  // --------------------------------------------------------------------------
  // End-to-end scenarios: several conditional grants live at once, checking
  // balances, states and solvency after each journey.
  // --------------------------------------------------------------------------

  /// @dev Without vaults, the contract must hold exactly the escrow plus grantor credits.
  function _assertSolvent() internal view {
    uint256 _owed;
    for (uint256 _i = 0; _i < grants.nextId(); _i++) {
      IConditionalGrants.GrantStatus memory _st = _status(_i);
      _owed += _st.held + _st.grantorOwed;
    }
    assertEq(usdt.balanceOf(address(grants)), _owed, 'contract balance != escrow + grantor credits');
  }

  function test_scenario_happyPathWithHelpersAndOverpayment() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.prank(coop);
    grants.payBack(_id, 300e6);
    vm.prank(helper);
    grants.payBack(_id, 200e6);
    _assertSolvent();

    uint256 _coopBefore = usdt.balanceOf(coop);
    vm.prank(coop);
    grants.payBack(_id, 10_000e6); // capped at the 500 still owed
    assertEq(usdt.balanceOf(coop), _coopBefore - 500e6);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.PaidBack));

    vm.prank(stranger);
    grants.releaseGrant(_id);
    vm.prank(stranger);
    grants.collect(_id);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
    assertEq(usdt.balanceOf(bread), START_BAL - GRANT, 'grantor nets out only the grant');
    // coop paid back 800 itself (helper covered 200), kept the advance's remainder and the grant
    assertEq(usdt.balanceOf(coop), START_BAL + ADVANCE - 800e6 + GRANT, 'grantee keeps the grant');
    _assertSolvent();
  }

  function test_scenario_cancelAndExpiryRefundEverything() public {
    uint256 _open = _create(address(0), GRANT);
    vm.prank(bread);
    IConditionalGrants.GrantTerms memory _t = _terms(address(0), GRANT);
    uint256 _unnamed = grants.create(_t, address(0));
    _assertSolvent();

    vm.prank(bread);
    grants.cancel(_open);
    assertEq(uint256(grants.grantState(_open)), uint256(IConditionalGrants.GrantState.Cancelled));

    vm.warp(_t.acceptBy);
    assertEq(uint256(grants.grantState(_unnamed)), uint256(IConditionalGrants.GrantState.Expired));
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.setGrantee(_unnamed, coop);
    vm.prank(bread);
    grants.cancel(_unnamed);

    assertEq(usdt.balanceOf(bread), START_BAL, 'grantor fully refunded');
    _assertSolvent();
  }

  function test_scenario_defaultThenGranteeStillPaysBack() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    uint256 _other = _createAccepted(address(0), GRANT); // stays open alongside
    vm.prank(coop);
    grants.payBack(_id, 400e6);

    vm.warp(_status(_id).payBackBy + grants.RECLAIM_GRACE_PERIOD());
    vm.prank(bread);
    grants.reclaimGrant(_id);
    _assertSolvent();

    vm.prank(coop);
    grants.payBack(_id, 600e6);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Defaulted));
    grants.collect(_id);
    assertEq(uint256(grants.grantState(_other)), uint256(IConditionalGrants.GrantState.Overdue));
    _assertSolvent();
  }

  function test_scenario_extendThenComplete() public {
    uint256 _id = _createAccepted(address(0), GRANT);
    vm.warp(_status(_id).payBackBy + 1 days);
    vm.prank(bread);
    grants.extendPayBackBy(_id, block.timestamp + 30 days);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Active));

    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    grants.releaseGrant(_id);
    grants.collect(_id);
    assertEq(usdt.balanceOf(coop), START_BAL + GRANT);
    _assertSolvent();
  }

  function test_scenario_zeroGrantIsAPlainAdvance() public {
    uint256 _id = _createAccepted(address(0), 0);
    vm.warp(_status(_id).payBackBy + grants.RECLAIM_GRACE_PERIOD());
    vm.prank(bread);
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.reclaimGrant(_id);

    vm.prank(coop);
    grants.payBack(_id, ADVANCE);
    assertEq(uint256(grants.grantState(_id)), uint256(IConditionalGrants.GrantState.Completed));
    vm.expectRevert(IConditionalGrants.InvalidState.selector);
    grants.releaseGrant(_id);
    grants.collect(_id);
    assertEq(usdt.balanceOf(bread), START_BAL);
    _assertSolvent();
  }
}
