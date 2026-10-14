// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';
import {ReentrancyGuardUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IConditionalGrants} from 'interfaces/IConditionalGrants.sol';

using SafeERC20 for IERC20;

/**
 * @title ConditionalGrants
 * @notice Conditional grants: a grantor funds a zero-interest advance plus an optional grant, the
 *         named grantee accepts the exact terms and receives the advance, and the grant unlocks once
 *         the advance is paid back in full. Escrowed funds can earn yield in an allowlisted ERC-4626
 *         vault; all yield belongs to the grantor. See docs/conditional-grants.md for the design
 *         rationale.
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
  mapping(address vault => bool status) internal _allowedVaults;
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

  /// @inheritdoc IConditionalGrants
  function setVaultAllowed(address _vault, bool _allowed) external override onlyOwner {
    _allowedVaults[_vault] = _allowed;
    emit VaultAllowed(_vault, _allowed);
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
    if (
      _grantTerms.vault != address(0)
        && (!_allowedVaults[_grantTerms.vault] || IERC4626(_grantTerms.vault).asset() != _grantTerms.token)
    ) revert InvalidVault();
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
    IERC20(_grantTerms.token).safeTransferFrom(msg.sender, address(this), _total);
    _escrow(_id, _total);

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
    uint256 _refunded = _releaseAll(_id, msg.sender);

    emit GrantCancelled(_id, _refunded);
  }

  /// @inheritdoc IConditionalGrants
  function reclaimGrant(uint256 _id) external override nonReentrant onlyGrantor(_id) {
    GrantState _s = _state(_id);
    if ((_s != GrantState.Overdue && _s != GrantState.PaidBack) || _terms[_id].grant == 0) revert InvalidState();
    if (block.timestamp < _reclaimableAt(_id)) revert ReclaimTooEarly();

    _status[_id].grantReclaimed = true;
    uint256 _amount = _releaseAll(_id, msg.sender);

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

    uint256 _disbursed = _release(_id, _t.advance, msg.sender);
    _st.disbursed = _disbursed;
    // A total vault loss leaves nothing to pay back: the advance counts as paid back right away.
    if (_disbursed == 0) _st.paidBackAt = block.timestamp;

    // Nothing left to escrow: credit any yield earned while the offer was open to the grantor.
    if (_t.grant == 0) _creditRemainingToGrantor(_id);

    emit GrantAccepted(_id, msg.sender, _disbursed, _st.payBackBy);
  }

  /// @inheritdoc IConditionalGrants
  function payBack(uint256 _id, uint256 _amount) external override nonReentrant onlyExisting(_id) {
    if (_amount == 0) revert InvalidAmount();
    GrantStatus storage _st = _status[_id];
    if (_st.acceptedAt == 0 || _st.paidBack >= _st.disbursed) revert InvalidState();

    uint256 _owed = _st.disbursed - _st.paidBack;
    uint256 _applied = _amount < _owed ? _amount : _owed;
    _st.paidBack += _applied;
    _st.grantorOwed += _applied;
    if (_st.paidBack == _st.disbursed) _st.paidBackAt = block.timestamp;

    IERC20(_terms[_id].token).safeTransferFrom(msg.sender, address(this), _applied);

    emit AdvancePaidBack(_id, msg.sender, _applied, _st.paidBack);
  }

  /// @inheritdoc IConditionalGrants
  function releaseGrant(uint256 _id) external override nonReentrant onlyExisting(_id) {
    if (_state(_id) != GrantState.PaidBack) revert InvalidState();

    GrantStatus storage _st = _status[_id];
    _st.grantPaid = true;
    uint256 _paid = _release(_id, _terms[_id].grant, _st.grantee);
    _creditRemainingToGrantor(_id);

    emit GrantReleased(_id, _st.grantee, _paid);
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
    _amount = _status[_id].disbursed - _status[_id].paidBack;
  }

  /// @inheritdoc IConditionalGrants
  function escrowValue(uint256 _id) external view override onlyExisting(_id) returns (uint256 _amount) {
    address _vault = _terms[_id].vault;
    uint256 _held = _status[_id].held;
    _amount = _vault == address(0) ? _held : IERC4626(_vault).convertToAssets(_held);
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

  /// @inheritdoc IConditionalGrants
  function isVaultAllowed(address _vault) external view override returns (bool _allowed) {
    _allowed = _allowedVaults[_vault];
  }

  // =======================
  // INTERNAL
  // =======================

  /// @dev Put tokens already held by this contract into the conditional grant's escrow (vault or plain balance).
  function _escrow(uint256 _id, uint256 _amount) internal {
    address _vault = _terms[_id].vault;
    if (_vault == address(0)) {
      _status[_id].held += _amount;
      return;
    }
    IERC20(_terms[_id].token).forceApprove(_vault, _amount);
    _status[_id].held += IERC4626(_vault).deposit(_amount, address(this));
  }

  /**
   * @dev Pay up to `_amount` tokens out of the conditional grant's escrow to `_to`. If the vault cannot cover
   *      the full amount (it lost value), everything left in escrow is paid instead.
   * @return _paid The tokens actually paid.
   */
  function _release(uint256 _id, uint256 _amount, address _to) internal returns (uint256 _paid) {
    GrantStatus storage _st = _status[_id];
    address _vault = _terms[_id].vault;
    if (_vault == address(0)) {
      _paid = _amount <= _st.held ? _amount : _st.held;
      _st.held -= _paid;
      IERC20(_terms[_id].token).safeTransfer(_to, _paid);
      return _paid;
    }
    if (IERC4626(_vault).previewWithdraw(_amount) <= _st.held) {
      _st.held -= IERC4626(_vault).withdraw(_amount, _to, address(this));
      _paid = _amount;
    } else {
      uint256 _shares = _st.held;
      _st.held = 0;
      _paid = IERC4626(_vault).redeem(_shares, _to, address(this));
    }
  }

  /// @dev Pay the conditional grant's entire escrow, including yield, to `_to`.
  function _releaseAll(uint256 _id, address _to) internal returns (uint256 _paid) {
    GrantStatus storage _st = _status[_id];
    uint256 _held = _st.held;
    _st.held = 0;
    address _vault = _terms[_id].vault;
    if (_vault == address(0)) {
      if (_held > 0 && _to != address(this)) IERC20(_terms[_id].token).safeTransfer(_to, _held);
      return _held;
    }
    if (_held > 0) _paid = IERC4626(_vault).redeem(_held, _to, address(this));
  }

  /// @dev Convert whatever is left in escrow (yield and rounding dust) into a grantor credit.
  function _creditRemainingToGrantor(uint256 _id) internal {
    uint256 _amount = _releaseAll(_id, address(this));
    if (_amount == 0) return;
    _status[_id].grantorOwed += _amount;
    emit YieldCredited(_id, _amount);
  }

  /// @dev Earliest reclaim time: a grace period after the deadline while unpaid, or a long wait
  ///      after full pay-back if the grant was never released. 0 when there is nothing to reclaim,
  ///      including an open-ended grant with no deadline set.
  function _reclaimableAt(uint256 _id) internal view returns (uint256 _timestamp) {
    GrantStatus storage _st = _status[_id];
    if (_terms[_id].grant == 0 || _st.cancelled || _st.acceptedAt == 0 || _st.grantPaid || _st.grantReclaimed) {
      return 0;
    }
    if (_st.paidBack >= _st.disbursed) return _st.paidBackAt + STUCK_GRANT_PERIOD;
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
    if (_st.paidBack >= _st.disbursed) {
      return (_st.grantPaid || _terms[_id].grant == 0) ? GrantState.Completed : GrantState.PaidBack;
    }
    return (_st.payBackBy == 0 || block.timestamp < _st.payBackBy) ? GrantState.Active : GrantState.Overdue;
  }
}
