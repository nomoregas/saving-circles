// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IConditionalGrants} from 'interfaces/IConditionalGrants.sol';

using SafeERC20 for IERC20;

/**
 * @title ConditionalGrants
 * @notice Conditional grants: a grantor funds a zero-interest advance plus an optional grant, the
 *         named grantee accepts the exact terms and receives the advance, and the grant unlocks once
 *         the advance is paid back in full. An optional fee is either paid in cash or taken out of the
 *         grant on release. See docs/conditional-grants.md for the design rationale.
 * @author Breadchain Collective
 */
contract ConditionalGrants is IConditionalGrants, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  /// @inheritdoc IConditionalGrants
  uint256 public constant override RECLAIM_GRACE_PERIOD = 7 days;

  /// @inheritdoc IConditionalGrants
  uint256 public constant override STUCK_GRANT_PERIOD = 90 days;

  /// @inheritdoc IConditionalGrants
  uint256 public constant override MAX_PAY_BACK_PERIOD = 3650 days;

  /// @inheritdoc IConditionalGrants
  uint256 public constant override DEADLINE_NOTICE_PERIOD = 30 days;

  /// @inheritdoc IConditionalGrants
  uint256 public nextId;

  mapping(address token => bool status) internal _allowedTokens;
  mapping(uint256 id => GrantTerms terms) internal _terms;
  mapping(uint256 id => GrantStatus status) internal _status;
  mapping(address grantor => uint256[] ids) internal _grantorGrants;
  mapping(address grantee => uint256[] ids) internal _granteeGrants;

  /// @dev Requires the conditional grant exists
  modifier onlyExisting(uint256 _id) {
    if (_id >= nextId) revert GrantNotFound();
    _;
  }

  /// @dev Requires the caller is the grantor of the conditional grant
  modifier onlyGrantor(uint256 _id) {
    if (_id >= nextId) revert GrantNotFound();
    if (msg.sender != _status[_id].grantor) revert NotGrantor();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /// @inheritdoc IConditionalGrants
  function initialize(address _owner) external override initializer {
    __Ownable_init(_owner);
    __ReentrancyGuard_init();
  }

  // =======================
  // ADMIN
  // =======================

  /// @inheritdoc IConditionalGrants
  function setTokenAllowed(address _token, bool _allowed) external override onlyOwner {
    _allowedTokens[_token] = _allowed;
    emit TokenAllowed(_token, _allowed);
  }

  // =======================
  // GRANTOR
  // =======================

  /// @inheritdoc IConditionalGrants
  function create(
    GrantTerms calldata _grantTerms,
    address _grantee
  ) external override nonReentrant returns (uint256 _id) {
    if (!_allowedTokens[_grantTerms.token]) revert TokenNotAllowed();
    if (_grantTerms.advance == 0) revert InvalidAdvance();
    if (_grantTerms.acceptBy <= block.timestamp) revert InvalidAcceptBy();
    if (_grantTerms.payBackPeriod > MAX_PAY_BACK_PERIOD) revert InvalidPayBackPeriod();
    if (_grantee == msg.sender) revert InvalidGrantee();

    _id = nextId++;
    _terms[_id] = _grantTerms;
    _status[_id].grantor = msg.sender;
    _grantorGrants[msg.sender].push(_id);
    if (_grantee != address(0)) {
      _status[_id].grantee = _grantee;
      _granteeGrants[_grantee].push(_id);
    }

    uint256 _total = _grantTerms.advance + _grantTerms.grant;
    _status[_id].held = _total;
    IERC20(_grantTerms.token).safeTransferFrom(msg.sender, address(this), _total);

    emit GrantCreated(_id, msg.sender, _grantee, _grantTerms);
  }

  /// @inheritdoc IConditionalGrants
  function setGrantee(uint256 _id, address _grantee) external override onlyGrantor(_id) {
    if (_state(_id) != GrantState.Offered) revert InvalidState();
    if (_status[_id].grantee != address(0)) revert GranteeAlreadySet();
    if (_grantee == address(0) || _grantee == msg.sender) revert InvalidGrantee();

    _status[_id].grantee = _grantee;
    _granteeGrants[_grantee].push(_id);

    emit GranteeSet(_id, _grantee);
  }

  /// @inheritdoc IConditionalGrants
  function cancel(uint256 _id) external override nonReentrant onlyGrantor(_id) {
    GrantState _s = _state(_id);
    if (_s != GrantState.Offered && _s != GrantState.Expired) revert InvalidState();

    _status[_id].cancelled = true;
    uint256 _refunded = _releaseHeld(_id, msg.sender);

    emit GrantCancelled(_id, _refunded);
  }

  /// @inheritdoc IConditionalGrants
  function reclaimGrant(uint256 _id) external override nonReentrant onlyGrantor(_id) {
    GrantState _s = _state(_id);
    if ((_s != GrantState.Overdue && _s != GrantState.PaidBack) || _terms[_id].grant == 0) revert InvalidState();
    if (block.timestamp < _reclaimableAt(_id)) revert ReclaimTooEarly();

    _status[_id].grantReclaimed = true;
    uint256 _amount = _releaseHeld(_id, msg.sender);

    emit GrantReclaimed(_id, _amount);
  }

  /// @inheritdoc IConditionalGrants
  function extendPayBackBy(uint256 _id, uint256 _newPayBackBy) external override onlyGrantor(_id) {
    GrantState _s = _state(_id);
    if (_s != GrantState.Active && _s != GrantState.Overdue) revert InvalidState();
    // An open-ended grant gets its first deadline through setPayBackBy, which enforces the notice period.
    if (_status[_id].payBackBy == 0) revert InvalidState();
    if (_newPayBackBy <= _status[_id].payBackBy || _newPayBackBy <= block.timestamp) revert InvalidPayBackPeriod();

    _status[_id].payBackBy = _newPayBackBy;

    emit PayBackByExtended(_id, _newPayBackBy);
  }

  /// @inheritdoc IConditionalGrants
  function setPayBackBy(uint256 _id, uint256 _payBackBy) external override onlyGrantor(_id) {
    if (_state(_id) != GrantState.Active || _status[_id].payBackBy != 0) revert InvalidState();
    if (_payBackBy < block.timestamp + DEADLINE_NOTICE_PERIOD) revert InvalidPayBackPeriod();

    _status[_id].payBackBy = _payBackBy;

    emit PayBackBySet(_id, _payBackBy);
  }

  /// @inheritdoc IConditionalGrants
  function collect(uint256 _id) external override nonReentrant onlyExisting(_id) {
    GrantStatus storage _st = _status[_id];
    uint256 _amount = _st.grantorOwed;
    if (_amount == 0) revert NothingToCollect();

    _st.grantorOwed = 0;
    IERC20(_terms[_id].token).safeTransfer(_st.grantor, _amount);

    emit GrantorCollected(_id, _st.grantor, _amount);
  }

  // =======================
  // GRANTEE
  // =======================

  /// @inheritdoc IConditionalGrants
  function accept(uint256 _id, bytes32 _termsHash) external override nonReentrant onlyExisting(_id) {
    GrantStatus storage _st = _status[_id];
    GrantTerms storage _t = _terms[_id];
    if (msg.sender != _st.grantee) revert NotGrantee();
    if (_state(_id) != GrantState.Offered) revert InvalidState();
    if (_termsHash != _t.termsHash) revert TermsMismatch();

    _st.acceptedAt = block.timestamp;
    // A zero pay-back period means no deadline until the grantor sets one with setPayBackBy.
    if (_t.payBackPeriod != 0) _st.payBackBy = block.timestamp + _t.payBackPeriod;

    _st.held -= _t.advance;
    IERC20(_t.token).safeTransfer(msg.sender, _t.advance);

    emit GrantAccepted(_id, msg.sender, _t.advance, _st.payBackBy);
  }

  /// @inheritdoc IConditionalGrants
  function payBack(uint256 _id, uint256 _amount) external override nonReentrant onlyExisting(_id) {
    if (_amount == 0) revert InvalidAmount();
    GrantStatus storage _st = _status[_id];
    GrantTerms storage _t = _terms[_id];
    uint256 _total = _t.advance + _t.fee;
    if (_st.acceptedAt == 0 || _st.paidBack >= _total) revert InvalidState();

    uint256 _owed = _total - _st.paidBack;
    uint256 _applied = _amount < _owed ? _amount : _owed;
    uint256 _unlock = _unlockAmount(_id);
    bool _wasLocked = _st.paidBack < _unlock;
    _st.paidBack += _applied;
    _st.grantorOwed += _applied;
    if (_wasLocked && _st.paidBack >= _unlock) _st.paidBackAt = block.timestamp;

    IERC20(_terms[_id].token).safeTransferFrom(msg.sender, address(this), _applied);

    emit AdvancePaidBack(_id, msg.sender, _applied, _st.paidBack);
  }

  /// @inheritdoc IConditionalGrants
  function releaseGrant(uint256 _id) external override nonReentrant onlyExisting(_id) {
    if (_state(_id) != GrantState.PaidBack) revert InvalidState();

    GrantStatus storage _st = _status[_id];
    GrantTerms storage _t = _terms[_id];
    // Whatever fee is still unpaid comes out of the grant. Reaching PaidBack guarantees it fits.
    uint256 _feeFromGrant = _t.advance + _t.fee - _st.paidBack;
    if (_feeFromGrant > 0 && msg.sender != _st.grantee) revert NotGrantee();

    _st.grantPaid = true;
    _st.paidBack += _feeFromGrant;
    _st.grantorOwed += _feeFromGrant;
    _st.held -= _feeFromGrant;
    uint256 _paid = _releaseHeld(_id, _st.grantee);

    emit GrantReleased(_id, _st.grantee, _paid, _feeFromGrant);
  }

  // =======================
  // VIEWS
  // =======================

  /// @inheritdoc IConditionalGrants
  function getGrant(uint256 _id)
    external
    view
    override
    onlyExisting(_id)
    returns (GrantTerms memory _grantTerms, GrantStatus memory _grantStatus)
  {
    _grantTerms = _terms[_id];
    _grantStatus = _status[_id];
  }

  /// @inheritdoc IConditionalGrants
  function grantState(uint256 _id) external view override onlyExisting(_id) returns (GrantState _s) {
    _s = _state(_id);
  }

  /// @inheritdoc IConditionalGrants
  function outstanding(uint256 _id) external view override onlyExisting(_id) returns (uint256 _amount) {
    GrantStatus storage _st = _status[_id];
    if (_st.acceptedAt != 0) _amount = _terms[_id].advance + _terms[_id].fee - _st.paidBack;
  }

  /// @inheritdoc IConditionalGrants
  function getGrantorGrants(address _grantor) external view override returns (uint256[] memory _ids) {
    _ids = _grantorGrants[_grantor];
  }

  /// @inheritdoc IConditionalGrants
  function reclaimableAt(uint256 _id) external view override onlyExisting(_id) returns (uint256 _timestamp) {
    _timestamp = _reclaimableAt(_id);
  }

  /// @inheritdoc IConditionalGrants
  function getGranteeGrants(address _grantee) external view override returns (uint256[] memory _ids) {
    _ids = _granteeGrants[_grantee];
  }

  /// @inheritdoc IConditionalGrants
  function isTokenAllowed(address _token) external view override returns (bool _allowed) {
    _allowed = _allowedTokens[_token];
  }

  // =======================
  // INTERNAL
  // =======================

  /// @dev Pay everything still escrowed for the conditional grant to `_to`.
  function _releaseHeld(uint256 _id, address _to) internal returns (uint256 _paid) {
    _paid = _status[_id].held;
    _status[_id].held = 0;
    if (_paid > 0) IERC20(_terms[_id].token).safeTransfer(_to, _paid);
  }

  /// @dev What must be paid in cash to unlock the grant: the advance, plus any part of the fee the
  ///      grant is too small to cover. With no grant, that is the whole advance + fee.
  function _unlockAmount(uint256 _id) internal view returns (uint256 _amount) {
    GrantTerms storage _t = _terms[_id];
    _amount = _t.advance + (_t.fee > _t.grant ? _t.fee - _t.grant : 0);
  }

  /// @dev Earliest reclaim time: a grace period after the deadline while unpaid, or a long wait
  ///      after full pay-back if the grant was never released. 0 when there is nothing to reclaim,
  ///      including an open-ended grant with no deadline set.
  function _reclaimableAt(uint256 _id) internal view returns (uint256 _timestamp) {
    GrantStatus storage _st = _status[_id];
    if (_terms[_id].grant == 0 || _st.cancelled || _st.acceptedAt == 0 || _st.grantPaid || _st.grantReclaimed) {
      return 0;
    }
    if (_st.paidBack >= _unlockAmount(_id)) return _st.paidBackAt + STUCK_GRANT_PERIOD;
    // Open-ended and no deadline set yet: nothing can be reclaimed.
    if (_st.payBackBy == 0) return 0;
    _timestamp = _st.payBackBy + RECLAIM_GRACE_PERIOD;
  }

  /**
   * @dev Derive the lifecycle state. Order matters: cancellation and pre-acceptance first, then the
   *      grant outcome, then paying back, then the deadline.
   */
  function _state(uint256 _id) internal view returns (GrantState _s) {
    GrantStatus storage _st = _status[_id];
    if (_st.cancelled) return GrantState.Cancelled;
    if (_st.acceptedAt == 0) {
      return block.timestamp < _terms[_id].acceptBy ? GrantState.Offered : GrantState.Expired;
    }
    if (_st.grantReclaimed) return GrantState.Defaulted;
    if (_st.paidBack >= _unlockAmount(_id)) {
      return (_st.grantPaid || _terms[_id].grant == 0) ? GrantState.Completed : GrantState.PaidBack;
    }
    return (_st.payBackBy == 0 || block.timestamp < _st.payBackBy) ? GrantState.Active : GrantState.Overdue;
  }
}
