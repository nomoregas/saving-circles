// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ProxyAdmin} from '@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol';
import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {StdInvariant} from 'forge-std/StdInvariant.sol';
import {Test} from 'forge-std/Test.sol';

import {ConditionalGrants} from '../../src/contracts/ConditionalGrants.sol';
import {IConditionalGrants} from '../../src/interfaces/IConditionalGrants.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

import {ConditionalGrantsHandler} from './handlers/ConditionalGrantsHandler.sol';

/**
 * @notice Accounting must tie to custody exactly (no shortfall and no stranded surplus), and every
 *         grant's bookkeeping must match its derived state, after any sequence of actions.
 */
contract ConditionalGrantsInvariantsTest is StdInvariant, Test {
  ConditionalGrants public grants;
  MockERC20 public token;
  ConditionalGrantsHandler public handler;

  function setUp() public {
    address _owner = makeAddr('owner');
    grants = ConditionalGrants(
      address(
        new TransparentUpgradeableProxy(
          address(new ConditionalGrants()),
          address(new ProxyAdmin(_owner)),
          abi.encodeWithSelector(ConditionalGrants.initialize.selector, _owner)
        )
      )
    );
    token = new MockERC20('Tether USD', 'USDT');
    vm.prank(_owner);
    grants.setTokenAllowed(address(token), true);

    handler = new ConditionalGrantsHandler(grants, token);

    bytes4[] memory _selectors = new bytes4[](11);
    _selectors[0] = ConditionalGrantsHandler.create.selector;
    _selectors[1] = ConditionalGrantsHandler.setGrantee.selector;
    _selectors[2] = ConditionalGrantsHandler.accept.selector;
    _selectors[3] = ConditionalGrantsHandler.payBack.selector;
    _selectors[4] = ConditionalGrantsHandler.releaseGrant.selector;
    _selectors[5] = ConditionalGrantsHandler.cancel.selector;
    _selectors[6] = ConditionalGrantsHandler.reclaimGrant.selector;
    _selectors[7] = ConditionalGrantsHandler.extendPayBackBy.selector;
    _selectors[8] = ConditionalGrantsHandler.setPayBackBy.selector;
    _selectors[9] = ConditionalGrantsHandler.collect.selector;
    _selectors[10] = ConditionalGrantsHandler.warp.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: _selectors}));
    targetContract(address(handler));
  }

  /// @dev Token balance equals escrow plus grantor credits, exactly.
  function invariant_balanceEqualsEscrowPlusCredits() public view {
    uint256 _owed;
    for (uint256 _i = 0; _i < grants.nextId(); _i++) {
      (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_i);
      _owed += _st.held + _st.grantorOwed;
    }
    assertEq(token.balanceOf(address(grants)), _owed);
  }

  /// @dev Every token in was matched by a token out or is still held.
  function invariant_ghostFlowsMatchBalance() public view {
    assertEq(token.balanceOf(address(grants)), handler.ghostIn() - handler.ghostOut());
  }

  /// @dev Per grant, the stored numbers agree with the derived state.
  function invariant_bookkeepingMatchesState() public view {
    for (uint256 _i = 0; _i < grants.nextId(); _i++) {
      (IConditionalGrants.GrantTerms memory _t, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_i);
      IConditionalGrants.GrantState _s = grants.grantState(_i);
      uint256 _total = _t.advance + _t.fee;

      assertLe(_st.paidBack, _total, 'paid more than advance + fee');
      assertEq(grants.outstanding(_i), _st.acceptedAt == 0 ? 0 : _total - _st.paidBack, 'outstanding');

      if (_s == IConditionalGrants.GrantState.Offered || _s == IConditionalGrants.GrantState.Expired) {
        assertEq(_st.held, _t.advance + _t.grant, 'unaccepted escrow');
      } else if (_s == IConditionalGrants.GrantState.Cancelled) {
        assertEq(_st.held, 0, 'cancelled escrow');
      } else if (_st.grantPaid || _st.grantReclaimed) {
        assertEq(_st.held, 0, 'grant left after release or reclaim');
      } else {
        assertEq(_st.held, _t.grant, 'waiting grant');
      }

      if (_s == IConditionalGrants.GrantState.Completed) {
        assertEq(grants.outstanding(_i), 0, 'completed with money owed');
      }
      if (_s == IConditionalGrants.GrantState.PaidBack) {
        // The unpaid fee must always fit in the grant that will cover it
        assertLe(_total - _st.paidBack, _t.grant, 'fee due exceeds grant');
      }
    }
  }
}
