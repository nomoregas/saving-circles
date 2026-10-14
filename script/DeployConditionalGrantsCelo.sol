// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from '@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol';
import {Script} from 'forge-std/Script.sol';
import {console2} from 'forge-std/console2.sol';

import {CELO_SEPOLIA_USDC, CELO_USDT} from 'script/Registry.sol';

import {ConditionalGrants} from '../src/contracts/ConditionalGrants.sol';

uint256 constant CONDITIONAL_GRANTS_CELO_SEPOLIA_CHAIN_ID = 11_142_220;

/**
 * @title Deploy ConditionalGrants (Celo)
 * @notice Deploys ConditionalGrants behind a transparent proxy and allows the stablecoin used for
 *         advances and grants: USDT on mainnet, USDC on Celo Sepolia. GRANT_TOKEN_ADDRESS
 *         overrides either default.
 *         If GRANT_VAULT_ADDRESS is set (an ERC-4626 vault over that token, e.g. the Aave
 *         v3 static aToken wrapper for USDT on Celo), it is allowed for escrow yield too.
 *         The broadcasting key MUST be ADMIN_ADDRESS, since the allowlist setters are onlyOwner.
 */
contract DeployConditionalGrantsCelo is Script {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    address grantToken = vm.envOr('GRANT_TOKEN_ADDRESS', _defaultGrantToken());
    address vault = vm.envOr('GRANT_VAULT_ADDRESS', address(0));

    vm.startBroadcast();

    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new ConditionalGrants()), admin, abi.encodeWithSelector(ConditionalGrants.initialize.selector, admin)
    );
    ConditionalGrants(address(proxy)).setTokenAllowed(grantToken, true);
    if (vault != address(0)) ConditionalGrants(address(proxy)).setVaultAllowed(vault, true);

    vm.stopBroadcast();

    console2.log('ConditionalGrants proxy:', address(proxy));
  }

  function _defaultGrantToken() internal view returns (address _token) {
    _token = block.chainid == CONDITIONAL_GRANTS_CELO_SEPOLIA_CHAIN_ID ? CELO_SEPOLIA_USDC : CELO_USDT;
  }
}
