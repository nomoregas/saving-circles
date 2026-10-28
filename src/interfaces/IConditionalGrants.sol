// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IConditionalGrants
 * @notice Interface for conditional grants: a grantor offers a zero-interest advance to a named
 *         grantee and escrows an optional grant that unlocks once the advance is paid back in full.
 *         The grantor funds everything at create(), the grantee accepts the exact terms on-chain and
 *         pays back in any amounts, and the grant can be released to the grantee as soon as
 *         cumulative payments reach the advance. If the grantee is late, the grantor may reclaim
 *         the grant; the advance remains owed and can still be paid back.
 *         The grantor may also charge a fee. The grantee owes advance + fee, but only the advance
 *         (plus any part of the fee the grant cannot cover) must be paid to unlock the grant: on
 *         release, any unpaid fee is taken out of the grant and credited to the grantor.
 */
interface IConditionalGrants {
  /**
   * @notice Lifecycle state of a conditional grant (derived, see grantState()).
   * @dev Offered = 0 funded and waiting for the grantee to accept, before acceptBy.
   *      Expired = 1 not accepted by acceptBy; the grantor can cancel for a full refund.
   *      Cancelled = 2 the grantor withdrew the offer before acceptance. Terminal.
   *      Active = 3 accepted, advance not fully paid back, before payBackBy (or open-ended with no
   *                deadline set yet).
   *      Overdue = 4 accepted, advance not fully paid back, at/after payBackBy. The grantee may still
   *                 pay back and claim the grant until the grantor reclaims it, which is only
   *                 allowed RECLAIM_GRACE_PERIOD after payBackBy.
   *      PaidBack = 5 advance paid back (plus any fee the grant cannot cover); the grant is waiting to
   *                  be released to the grantee, minus any unpaid fee. If
   *                  it is still unreleased STUCK_GRANT_PERIOD after paidBackAt (e.g. the grantee
   *                  can no longer receive the token), the grantor may reclaim it.
   *      Completed = 6 advance and fee settled and the grant (if any) paid to the grantee. Terminal.
   *      Defaulted = 7 the grantor reclaimed the grant (late payment, or a grant left unreleased).
   *                   Terminal for the grant; any remaining advance can still be paid back.
   */
  enum GrantState {
    Offered,
    Expired,
    Cancelled,
    Active,
    Overdue,
    PaidBack,
    Completed,
    Defaulted
  }

  /**
   * @notice Immutable terms of a conditional grant, fixed at create().
   * @param token The allowlisted ERC20 used for every transfer (e.g. USDT on Celo).
   * @param advance The amount advanced to the grantee on acceptance (> 0).
   * @param grant The amount released to the grantee once the advance is paid back; 0 makes this a
   *        plain zero-interest advance with no grant.
   * @param fee A fee the grantee owes on top of the advance (may be 0). The grantee can pay it in
   *        cash to receive the full grant, or leave it to be taken out of the grant on release.
   *        Any part of the fee larger than the grant must be paid in cash before the grant unlocks.
   * @param acceptBy Unix timestamp; the grantee must accept strictly before it.
   * @param payBackPeriod Seconds after acceptance until an unpaid advance becomes Overdue, at most
   *        MAX_PAY_BACK_PERIOD. 0 makes the grant open-ended: no deadline until the grantor sets one
   *        with setPayBackBy(), at least DEADLINE_NOTICE_PERIOD in the future.
   * @param termsHash Hash of the off-chain agreement (e.g. an IPFS document) the grantee signs
   *        up to by passing the same hash to accept(). May be zero if no document is used.
   */
  struct GrantTerms {
    address token;
    uint256 advance;
    uint256 grant;
    uint256 fee;
    uint256 acceptBy;
    uint256 payBackPeriod;
    bytes32 termsHash;
  }

  /**
   * @notice Mutable bookkeeping of a conditional grant.
   * @param grantor The creator and funder of the conditional grant.
   * @param grantee The only address that can accept; may be set after create() if left empty.
   * @param acceptedAt Acceptance timestamp, 0 until accepted.
   * @param payBackBy Timestamp at which an unpaid advance becomes Overdue, 0 until accepted or while
   *        an open-ended grant has no deadline. The grantor may push it later with extendPayBackBy().
   * @param paidBack Cumulative amount paid toward advance + fee (never exceeds advance + fee). Fee
   *        taken out of the grant on release counts as paid.
   * @param paidBackAt When paidBack first reached the amount that unlocks the grant, 0 until then.
   * @param held Tokens escrowed for this conditional grant: advance + grant before acceptance, then
   *        the grant until it is released or reclaimed.
   * @param grantorOwed Payments and fees credited to the grantor and not yet collected.
   * @param cancelled Whether the grantor cancelled before acceptance.
   * @param grantPaid Whether the grant was released to the grantee.
   * @param grantReclaimed Whether the grantor reclaimed the grant, after a late payment or after it
   *        was left unreleased for STUCK_GRANT_PERIOD.
   */
  struct GrantStatus {
    address grantor;
    address grantee;
    uint256 acceptedAt;
    uint256 payBackBy;
    uint256 paidBack;
    uint256 paidBackAt;
    uint256 held;
    uint256 grantorOwed;
    bool cancelled;
    bool grantPaid;
    bool grantReclaimed;
  }

  // =======================
  // EVENTS
  // =======================

  /**
   * @notice Emitted when the admin allows or disallows a token for new grants.
   * @param token The token address.
   * @param allowed Whether the token is now allowed.
   */
  event TokenAllowed(address indexed token, bool indexed allowed);

  /**
   * @notice Emitted when a grantor creates and funds a conditional grant offer.
   * @param id The new conditional grant id.
   * @param grantor The grantor.
   * @param grantee The named grantee, or address(0) if it will be set later.
   * @param terms The terms.
   */
  event GrantCreated(uint256 indexed id, address indexed grantor, address indexed grantee, GrantTerms terms);

  /**
   * @notice Emitted when the grantor names the grantee of an offer created without one.
   * @param id The conditional grant id.
   * @param grantee The grantee.
   */
  event GranteeSet(uint256 indexed id, address indexed grantee);

  /**
   * @notice Emitted when the grantor cancels an offer and is refunded.
   * @param id The conditional grant id.
   * @param refunded Tokens returned to the grantor.
   */
  event GrantCancelled(uint256 indexed id, uint256 refunded);

  /**
   * @notice Emitted when the grantee accepts the terms and receives the advance.
   * @param id The conditional grant id.
   * @param grantee The grantee.
   * @param advance Tokens paid to the grantee.
   * @param payBackBy The timestamp at which it becomes Overdue, or 0 for an open-ended grant.
   */
  event GrantAccepted(uint256 indexed id, address indexed grantee, uint256 advance, uint256 payBackBy);

  /**
   * @notice Emitted when part of the advance is paid back.
   * @param id The conditional grant id.
   * @param payer The address that paid (the grantee or anyone on their behalf).
   * @param amount Tokens applied to the advance.
   * @param totalPaidBack Cumulative amount paid toward advance + fee after this payment.
   */
  event AdvancePaidBack(uint256 indexed id, address indexed payer, uint256 amount, uint256 totalPaidBack);

  /**
   * @notice Emitted when the grant is released to the grantee.
   * @param id The conditional grant id.
   * @param grantee The grantee.
   * @param amount Tokens paid to the grantee.
   * @param feeFromGrant Unpaid fee taken out of the grant and credited to the grantor.
   */
  event GrantReleased(uint256 indexed id, address indexed grantee, uint256 amount, uint256 feeFromGrant);

  /**
   * @notice Emitted when the grantor reclaims the grant of an Overdue conditional grant.
   * @param id The conditional grant id.
   * @param amount Tokens returned to the grantor.
   */
  event GrantReclaimed(uint256 indexed id, uint256 amount);

  /**
   * @notice Emitted when the grantor moves the pay-back deadline later.
   * @param id The conditional grant id.
   * @param payBackBy The new deadline.
   */
  event PayBackByExtended(uint256 indexed id, uint256 payBackBy);

  /**
   * @notice Emitted when the grantor sets the first deadline on an open-ended grant.
   * @param id The conditional grant id.
   * @param payBackBy The deadline.
   */
  event PayBackBySet(uint256 indexed id, uint256 payBackBy);

  /**
   * @notice Emitted when the grantor's credited payments are paid out.
   * @param id The conditional grant id.
   * @param grantor The grantor.
   * @param amount Tokens paid.
   */
  event GrantorCollected(uint256 indexed id, address indexed grantor, uint256 amount);

  // =======================
  // ERRORS
  // =======================

  /// @notice Thrown when a token is not allowlisted
  error TokenNotAllowed();

  /// @notice Thrown when the advance is zero
  error InvalidAdvance();

  /// @notice Thrown when acceptBy is not in the future
  error InvalidAcceptBy();

  /// @notice Thrown when the pay-back period is above MAX_PAY_BACK_PERIOD, an extension does not move
  ///         payBackBy later and into the future, or a deadline set on an open-ended grant gives less
  ///         than DEADLINE_NOTICE_PERIOD notice
  error InvalidPayBackPeriod();

  /// @notice Thrown when the grantor reclaims the grant before reclaimableAt()
  error ReclaimTooEarly();

  /// @notice Thrown when a grantee address is zero or the grantor itself
  error InvalidGrantee();

  /// @notice Thrown when the grantee is already set
  error GranteeAlreadySet();

  /// @notice Thrown when a conditional grant id does not exist
  error GrantNotFound();

  /// @notice Thrown when the caller is not the grantor
  error NotGrantor();

  /// @notice Thrown when the caller is not the grantee
  error NotGrantee();

  /// @notice Thrown when the passed terms hash does not match the conditional grant
  error TermsMismatch();

  /// @notice Thrown when the conditional grant is not in a state that allows the action
  error InvalidState();

  /// @notice Thrown when a payment amount is zero, or advance + fee would overflow
  error InvalidAmount();

  /// @notice Thrown when there is nothing to collect
  error NothingToCollect();

  // =======================
  // ADMIN
  // =======================

  /**
   * @notice Initialize the contract behind its proxy.
   * @param owner The admin that manages the token allowlist.
   */
  function initialize(address owner) external;

  /**
   * @notice Allow or disallow a token for new grants.
   * @dev Fee-on-transfer and rebasing tokens must never be allowed. Existing conditional grants are unaffected.
   * @param token The token.
   * @param allowed Whether to allow it.
   */
  function setTokenAllowed(address token, bool allowed) external;

  // =======================
  // GRANTOR
  // =======================

  /**
   * @notice Create a conditional grant offer, pulling advance + grant from the caller, who becomes the grantor.
   * @param terms The terms.
   * @param grantee The grantee who may accept, or address(0) to name them later with setGrantee().
   * @return id The new conditional grant id.
   */
  function create(GrantTerms calldata terms, address grantee) external returns (uint256 id);

  /**
   * @notice Name the grantee of an offer created without one.
   * @param id The conditional grant id.
   * @param grantee The grantee.
   */
  function setGrantee(uint256 id, address grantee) external;

  /**
   * @notice Cancel an offer that has not been accepted (Offered or Expired), refunding the grantor.
   * @param id The conditional grant id.
   */
  function cancel(uint256 id) external;

  /**
   * @notice Reclaim the grant, either RECLAIM_GRACE_PERIOD after an unpaid advance's deadline (the
   *         advance stays owed) or STUCK_GRANT_PERIOD after it was paid back if the grant was never
   *         released. See reclaimableAt().
   * @param id The conditional grant id.
   */
  function reclaimGrant(uint256 id) external;

  /**
   * @notice Move the pay-back deadline later, e.g. to give the grantee more time. Reverts on an
   *         open-ended grant with no deadline yet; use setPayBackBy() instead.
   * @param id The conditional grant id.
   * @param newPayBackBy The new deadline; must be later than the current one, in the future, and at
   *        most MAX_PAY_BACK_PERIOD from now.
   */
  function extendPayBackBy(uint256 id, uint256 newPayBackBy) external;

  /**
   * @notice Set the first deadline on an open-ended grant (payBackPeriod 0). The grantee gets at least
   *         DEADLINE_NOTICE_PERIOD of notice; after that it behaves like any other deadline.
   * @param id The conditional grant id.
   * @param payBackBy The deadline; at least DEADLINE_NOTICE_PERIOD and at most MAX_PAY_BACK_PERIOD
   *        from now.
   */
  function setPayBackBy(uint256 id, uint256 payBackBy) external;

  /**
   * @notice Pay the grantor all credited payments. Callable by anyone.
   * @param id The conditional grant id.
   */
  function collect(uint256 id) external;

  // =======================
  // GRANTEE
  // =======================

  /**
   * @notice Accept the terms and receive the advance.
   * @param id The conditional grant id.
   * @param termsHash Must equal the conditional grant's termsHash, proving which agreement was accepted.
   */
  function accept(uint256 id, bytes32 termsHash) external;

  /**
   * @notice Pay toward the advance, then the fee. Callable by anyone on the grantee's behalf.
   *         Payments above the outstanding amount are capped, so only what is owed is pulled.
   * @param id The conditional grant id.
   * @param amount The maximum amount to pay back.
   */
  function payBack(uint256 id, uint256 amount) external;

  /**
   * @notice Release the grant to the grantee once the advance is paid back. Any unpaid fee is taken
   *         out of the grant and credited to the grantor; while that would happen, only the grantee
   *         may release, so the choice between paying the fee in cash and taking it from the grant
   *         stays theirs. Once the fee is paid, anyone may release. The grant always goes to the
   *         grantee.
   * @param id The conditional grant id.
   */
  function releaseGrant(uint256 id) external;

  // =======================
  // VIEWS
  // =======================

  /**
   * @notice How long after payBackBy the grantor must wait before reclaiming the grant, so a
   *         grantee finishing late cannot be front-run at the deadline.
   * @return period The grace period in seconds.
   */
  function RECLAIM_GRACE_PERIOD() external view returns (uint256 period);

  /**
   * @notice How long a paid-back grant may stay unreleased before the grantor can reclaim it.
   * @return period The period in seconds.
   */
  function STUCK_GRANT_PERIOD() external view returns (uint256 period);

  /**
   * @notice The longest allowed pay-back period.
   * @return period The period in seconds.
   */
  function MAX_PAY_BACK_PERIOD() external view returns (uint256 period);

  /**
   * @notice The minimum notice the grantor must give when setting a deadline on an open-ended grant.
   * @return period The period in seconds.
   */
  function DEADLINE_NOTICE_PERIOD() external view returns (uint256 period);

  /**
   * @notice When the grantor may reclaim the grant, or 0 if it cannot be reclaimed (no grant, not
   *         accepted, cancelled, already released or reclaimed). Moves with extendPayBackBy().
   * @param id The conditional grant id.
   * @return timestamp The earliest reclaim time.
   */
  function reclaimableAt(uint256 id) external view returns (uint256 timestamp);

  /**
   * @notice Get the next id that will be assigned.
   * @return nextId The next id.
   */
  function nextId() external view returns (uint256 nextId);

  /**
   * @notice Get a conditional grant's terms and status.
   * @param id The conditional grant id.
   * @return terms The immutable terms.
   * @return status The mutable status.
   */
  function getGrant(uint256 id) external view returns (GrantTerms memory terms, GrantStatus memory status);

  /**
   * @notice Get the derived lifecycle state of a conditional grant.
   * @param id The conditional grant id.
   * @return state The state.
   */
  function grantState(uint256 id) external view returns (GrantState state);

  /**
   * @notice Get the amount still owed: advance + fee minus paid back (0 before acceptance).
   * @param id The conditional grant id.
   * @return amount The outstanding advance.
   */
  function outstanding(uint256 id) external view returns (uint256 amount);

  /**
   * @notice Get all conditional grant ids created by a grantor.
   * @param grantor The grantor.
   * @return ids The conditional grant ids.
   */
  function getGrantorGrants(address grantor) external view returns (uint256[] memory ids);

  /**
   * @notice Get all conditional grant ids naming a grantee.
   * @param grantee The grantee.
   * @return ids The conditional grant ids.
   */
  function getGranteeGrants(address grantee) external view returns (uint256[] memory ids);

  /**
   * @notice Check whether a token is allowed for new grants.
   * @param token The token.
   * @return allowed Whether it is allowed.
   */
  function isTokenAllowed(address token) external view returns (bool allowed);
}
