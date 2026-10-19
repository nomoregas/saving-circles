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
 *         Any key can broadcast. The broadcaster owns the contract only long enough to allow the
 *         token, then ownership moves to ADMIN_ADDRESS, which also owns the ProxyAdmin from the
 *         start. ADMIN_ADDRESS can therefore be a multisig.
 */
contract DeployConditionalGrantsCelo is Script {
  function run() public {
    address admin = vm.envAddress('ADMIN_ADDRESS');
    address grantToken = vm.envOr('GRANT_TOKEN_ADDRESS', _defaultGrantToken());

    vm.startBroadcast();
    (, address deployer,) = vm.readCallers();

    TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
      address(new ConditionalGrants()), admin, abi.encodeWithSelector(ConditionalGrants.initialize.selector, deployer)
    );
    ConditionalGrants grants = ConditionalGrants(address(proxy));
    grants.setTokenAllowed(grantToken, true);
    grants.transferOwnership(admin);

    vm.stopBroadcast();

    console2.log('ConditionalGrants proxy:', address(proxy));
    console2.log('Allowed token:', grantToken);
    console2.log('Owner and ProxyAdmin owner:', admin);
  }

  function _defaultGrantToken() internal view returns (address _token) {
    _token = block.chainid == CONDITIONAL_GRANTS_CELO_SEPOLIA_CHAIN_ID ? CELO_SEPOLIA_USDC : CELO_USDT;
  }
}
