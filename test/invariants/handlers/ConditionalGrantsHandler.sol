// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from 'forge-std/Base.sol';
import {StdCheats} from 'forge-std/StdCheats.sol';
import {StdUtils} from 'forge-std/StdUtils.sol';

import {ConditionalGrants} from '../../../src/contracts/ConditionalGrants.sol';
import {IConditionalGrants} from '../../../src/interfaces/IConditionalGrants.sol';
import {MockERC20} from '../../mocks/MockERC20.sol';

/**
 * @notice Drives ConditionalGrants through random but valid sequences: several grantors and
 *         grantees, partial and over-payments by anyone, fees larger and smaller than the grant,
 *         open-ended grants, deadline changes, time jumps, reclaims and cancels. Every action
 *         checks its preconditions first so sequences reach deep states instead of reverting,
 *         and ghost totals track every token moved in and out.
 */
contract ConditionalGrantsHandler is CommonBase, StdCheats, StdUtils {
  ConditionalGrants public grants;
  MockERC20 public token;

  address[] public grantors;
  address[] public grantees;
  address public helper = makeAddr('helper');

  uint256 public ghostIn;
  uint256 public ghostOut;
  mapping(bytes32 action => uint256 count) public calls;

  constructor(ConditionalGrants _grants, MockERC20 _token) {
    grants = _grants;
    token = _token;
    for (uint256 i = 0; i < 3; i++) {
      grantors.push(makeAddr(string(abi.encodePacked('grantor', i))));
      grantees.push(makeAddr(string(abi.encodePacked('grantee', i))));
    }
    address[] memory all = new address[](7);
    for (uint256 i = 0; i < 3; i++) {
      all[i] = grantors[i];
      all[i + 3] = grantees[i];
    }
    all[6] = helper;
    for (uint256 i = 0; i < all.length; i++) {
      token.mint(all[i], 1e15);
      vm.prank(all[i]);
      token.approve(address(grants), type(uint256).max);
    }
  }

  // --------------------------------------------------------------------------
  // Actions
  // --------------------------------------------------------------------------

  function create(uint256 _seed, uint256 _advance, uint256 _grant, uint256 _fee, uint256 _period, bool _named) public {
    address _grantor = grantors[_seed % 3];
    address _grantee = _named ? grantees[(_seed / 3) % 3] : address(0);
    IConditionalGrants.GrantTerms memory _t = IConditionalGrants.GrantTerms({
      token: address(token),
      advance: bound(_advance, 1, 10_000e6),
      grant: bound(_grant, 0, 10_000e6),
      fee: bound(_fee, 0, 3000e6),
      acceptBy: block.timestamp + 7 days,
      // 0 makes it open-ended
      payBackPeriod: _period % 4 == 0 ? 0 : bound(_period, 1 days, 365 days),
      agreement: ''
    });
    vm.prank(_grantor);
    grants.create(_t, _grantee);
    ghostIn += _t.advance + _t.grant;
    calls['create']++;
  }

  function setGrantee(uint256 _idSeed, uint256 _granteeSeed) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _needsGrantee);
    if (!_ok) return;
    (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    vm.prank(_st.grantor);
    grants.setGrantee(_id, grantees[_granteeSeed % 3]);
    calls['setGrantee']++;
  }

  function accept(uint256 _idSeed) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _acceptable);
    if (!_ok) return;
    (IConditionalGrants.GrantTerms memory _t, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    vm.prank(_st.grantee);
    grants.accept(_id);
    ghostOut += _t.advance;
    calls['accept']++;
  }

  function payBack(uint256 _idSeed, uint256 _amount, uint256 _payerSeed) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _owes);
    if (!_ok) return;
    uint256 _owed = grants.outstanding(_id);
    (IConditionalGrants.GrantTerms memory _t, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    // Anyone may pay on the grantee's behalf; overpaying is capped by the contract
    address _payer = _payerSeed % 3 == 0 ? helper : _st.grantee;
    // Mix the realistic choices: exactly what unlocks the grant (fee left for the grant),
    // everything (fee in cash), or a random partial or over-payment
    uint256 _unlock = _t.advance + (_t.fee > _t.grant ? _t.fee - _t.grant : 0);
    uint256 _toUnlock = _unlock > _st.paidBack ? _unlock - _st.paidBack : 0;
    if (_amount % 3 == 0 && _toUnlock > 0) _amount = _toUnlock;
    else if (_amount % 3 == 1) _amount = _owed;
    else _amount = bound(_amount, 1, _owed * 2);
    vm.prank(_payer);
    grants.payBack(_id, _amount);
    ghostIn += _amount < _owed ? _amount : _owed;
    calls['payBack']++;
  }

  function releaseGrant(uint256 _idSeed, bool _byStranger) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _releasable);
    if (!_ok) return;
    (IConditionalGrants.GrantTerms memory _t, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    uint256 _feeDue = grants.outstanding(_id);
    if (_byStranger) {
      vm.prank(helper);
      if (_feeDue > 0) {
        // Only the grantee may choose to take the fee out of the grant
        vm.expectRevert(IConditionalGrants.NotGrantee.selector);
        grants.releaseGrant(_id);
        calls['releaseRefused']++;
        return;
      }
      grants.releaseGrant(_id);
    } else {
      vm.prank(_st.grantee);
      grants.releaseGrant(_id);
    }
    ghostOut += _t.grant - _feeDue;
    calls['release']++;
  }

  function cancel(uint256 _idSeed) public {
    // Cancel rarely, or most offers would never get accepted
    if (_idSeed % 4 != 0) return;
    (bool _ok, uint256 _id) = _find(_idSeed, _cancellable);
    if (!_ok) return;
    (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    vm.prank(_st.grantor);
    grants.cancel(_id);
    ghostOut += _st.held;
    calls['cancel']++;
  }

  function reclaimGrant(uint256 _idSeed) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _reclaimable);
    if (!_ok) return;
    (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    vm.prank(_st.grantor);
    grants.reclaimGrant(_id);
    ghostOut += _st.held;
    calls['reclaim']++;
  }

  function extendPayBackBy(uint256 _idSeed, uint256 _by) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _extendable);
    if (!_ok) return;
    (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    uint256 _from = _st.payBackBy > block.timestamp ? _st.payBackBy : block.timestamp;
    vm.prank(_st.grantor);
    grants.extendPayBackBy(_id, _from + bound(_by, 1, 90 days));
    calls['extend']++;
  }

  function setPayBackBy(uint256 _idSeed, uint256 _in) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _openEnded);
    if (!_ok) return;
    (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    // Read the notice period before pranking, or the view call would consume the prank
    uint256 _payBackBy = block.timestamp + bound(_in, grants.DEADLINE_NOTICE_PERIOD(), 120 days);
    vm.prank(_st.grantor);
    grants.setPayBackBy(_id, _payBackBy);
    calls['setPayBackBy']++;
  }

  function collect(uint256 _idSeed) public {
    (bool _ok, uint256 _id) = _find(_idSeed, _hasCredit);
    if (!_ok) return;
    (, IConditionalGrants.GrantStatus memory _st) = grants.getGrant(_id);
    grants.collect(_id);
    ghostOut += _st.grantorOwed;
    calls['collect']++;
  }

  function warp(uint256 _seconds) public {
    vm.warp(block.timestamp + bound(_seconds, 1 hours, 120 days));
    calls['warp']++;
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  /// @dev The first grant, starting from a random one, that is in the state an action needs.
  function _find(
    uint256 _seed,
    function(uint256) view returns (bool) _matches
  ) internal view returns (bool _ok, uint256 _id) {
    uint256 _n = grants.nextId();
    for (uint256 _i = 0; _i < _n; _i++) {
      _id = (_seed % _n + _i) % _n;
      if (_matches(_id)) return (true, _id);
    }
  }

  function _state(uint256 _id) internal view returns (IConditionalGrants.GrantState) {
    return grants.grantState(_id);
  }

  function _status(uint256 _id) internal view returns (IConditionalGrants.GrantStatus memory _st) {
    (, _st) = grants.getGrant(_id);
  }

  function _needsGrantee(uint256 _id) internal view returns (bool) {
    return _status(_id).grantee == address(0) && _state(_id) == IConditionalGrants.GrantState.Offered;
  }

  function _acceptable(uint256 _id) internal view returns (bool) {
    return _status(_id).grantee != address(0) && _state(_id) == IConditionalGrants.GrantState.Offered;
  }

  function _owes(uint256 _id) internal view returns (bool) {
    return grants.outstanding(_id) > 0;
  }

  function _releasable(uint256 _id) internal view returns (bool) {
    return _state(_id) == IConditionalGrants.GrantState.PaidBack;
  }

  function _cancellable(uint256 _id) internal view returns (bool) {
    IConditionalGrants.GrantState _s = _state(_id);
    return _s == IConditionalGrants.GrantState.Offered || _s == IConditionalGrants.GrantState.Expired;
  }

  function _reclaimable(uint256 _id) internal view returns (bool) {
    uint256 _at = grants.reclaimableAt(_id);
    return _at != 0 && block.timestamp >= _at;
  }

  function _extendable(uint256 _id) internal view returns (bool) {
    IConditionalGrants.GrantState _s = _state(_id);
    return (_s == IConditionalGrants.GrantState.Active || _s == IConditionalGrants.GrantState.Overdue)
      && _status(_id).payBackBy != 0;
  }

  function _openEnded(uint256 _id) internal view returns (bool) {
    return _status(_id).payBackBy == 0 && _state(_id) == IConditionalGrants.GrantState.Active;
  }

  function _hasCredit(uint256 _id) internal view returns (bool) {
    return _status(_id).grantorOwed > 0;
  }
}
