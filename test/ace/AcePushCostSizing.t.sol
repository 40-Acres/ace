// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNoReturnERC20} from "../mocks/MockNoReturnERC20.sol";
import {AceFixtures} from "../utils/AceFixtures.sol";
import {PushCostRig} from "../utils/PushCostRig.sol";

/// @notice A plain OpenZeppelin ERC20, which emits the `Transfer` event `MockERC20` leaves out.
contract OzPlainToken is ERC20 {
    constructor() ERC20("OZ Plain", "OZP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice FiatTokenV1-shaped USDC implementation: a pause read, TWO reads of a separate blacklist mapping, balances, `Transfer`.
/// @dev FiatTokenV2_2 packs the blacklist bit into the balance word, so this layout pays two more cold reads than live USDC.
contract UsdcShapedImpl {
    address public owner;
    address public pauser; // packed with `paused`, as FiatToken's Pausable packs them
    bool public paused;
    address public blacklister;
    mapping(address => bool) public blacklisted;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    modifier whenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!blacklisted[account], "Blacklistable: account is blacklisted");
        _;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 value) external whenNotPaused notBlacklisted(msg.sender) notBlacklisted(to) returns (bool) {
        require(msg.sender != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(value <= balanceOf[msg.sender], "ERC20: transfer amount exceeds balance");
        balanceOf[msg.sender] = balanceOf[msg.sender] - value;
        balanceOf[to] = balanceOf[to] + value;
        emit Transfer(msg.sender, to, value);
        return true;
    }
}

/// @notice zos AdminUpgradeabilityProxy-shaped, as USDC's FiatTokenProxy is: an admin-slot read, an implementation-slot read, a delegatecall.
contract UsdcShapedProxy {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3; // zos 2.x
    bytes32 internal constant ADMIN_SLOT = 0x10d6a54a4754c8869d6886b5f5d7fbfa5b4522237ea5c60d11bc4e7a1ff9390b; // zos 2.x

    constructor(address impl, address admin) {
        assembly {
            sstore(IMPLEMENTATION_SLOT, impl)
            sstore(ADMIN_SLOT, admin)
        }
    }

    fallback() external {
        address admin;
        assembly {
            admin := sload(ADMIN_SLOT)
        }
        require(msg.sender != admin, "Cannot call fallback function from the proxy admin");
        assembly {
            let impl := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @notice TetherToken-shaped, returning NOTHING: a pause read, a sender-only blacklist read, the deprecation word, the fee pair, `Transfer`.
/// @dev The layout packs `owner` with `paused` and `upgradedAddress` with `deprecated`, as the mainnet contract's does.
contract UsdtShapedToken {
    address public owner;
    bool public paused;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public basisPointsRate;
    uint256 public maximumFee;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlackListed;
    address public upgradedAddress;
    bool public deprecated; // the deprecated branch forwards to an upgrade; mainnet has never taken it

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 value) external {
        require(!paused);
        require(!isBlackListed[msg.sender]);
        require(!deprecated);
        require(msg.data.length >= 68);
        uint256 fee = (value * basisPointsRate) / 10000;
        if (fee > maximumFee) fee = maximumFee;
        uint256 sendAmount = value - fee;
        balanceOf[msg.sender] = balanceOf[msg.sender] - value;
        balanceOf[to] = balanceOf[to] + sendAmount;
        if (fee > 0) {
            balanceOf[owner] = balanceOf[owner] + fee;
            emit Transfer(msg.sender, owner, fee);
        }
        emit Transfer(msg.sender, to, sendAmount);
    }
}

/// @title AcePushCostSizing
/// @notice What `Ace.pushToken` needs as a budget on the offline shapes: MockERC20, OZ ERC20, a proxied USDC shape, MockNoReturn, a USDT shape.
/// @notice Live USDC and USDT are measured by the same rig in `test/fork/AcePushCostSizingFork.t.sol`.
/// @dev All-cold minus warm is asserted per shape from EIP-2929 prices, which shows the warm-up pull re-warmed what a repay's pull would.
/// @dev Read the table with `scripts/test-trace.sh test/ace/AcePushCostSizing.t.sol PUSH-COST 0`, under `FOUNDRY_PROFILE=deploy`.
contract AcePushCostSizingTest is PushCostRig {
    address internal plain;
    address internal oz;
    address internal usdc; // the proxy
    address internal noRet;
    address internal usdt;
    address internal constant PROXY_ADMIN = address(0xAD314); // may not call through the proxy, as zos forbids

    function _newPlain() internal returns (address) {
        return address(new MockERC20("Plain", "PLN", 6));
    }

    function _newOz() internal returns (address) {
        return address(new OzPlainToken());
    }

    function _newUsdc() internal returns (address) {
        return address(new UsdcShapedProxy(address(new UsdcShapedImpl()), PROXY_ADMIN));
    }

    function _newNoRet() internal returns (address) {
        return address(new MockNoReturnERC20("No Return", "NR", 6));
    }

    function _newUsdt() internal returns (address) {
        return address(new UsdtShapedToken());
    }

    /// @dev The main instance, funded with the payer, and `POOL` funded copies, each with its own implementation where it has one.
    function _build(function() internal returns (address) make) internal returns (address main) {
        main = make();
        _fund(main, false, true);
        for (uint256 i; i < POOL; i++) {
            address copy = make();
            _fund(copy, false, false);
            fresh[main].push(copy);
        }
    }

    function setUp() public {
        ace = AceFixtures.newAce();
        lenderEmpty = makeAddr("push-cost empty lender");
        plain = _build(_newPlain);
        oz = _build(_newOz);
        usdc = _build(_newUsdc);
        noRet = _build(_newNoRet);
        usdt = _build(_newUsdt);
    }

    /// @notice MockERC20: no event, two balance words. All cold over warm is the account (2,500) plus the hub word (4,800).
    function test_PushCost_MockERC20() public {
        (Cost[4] memory cs,) = _shape("MockERC20        ", plain, address(0), 1);
        assertEq(cs[2].used - cs[0].used, 2_500 + 4_800, "RIG: all cold must re-pay the token account and the hub's word");
    }

    /// @notice OZ ERC20: MockERC20 plus the `Transfer` log, which reads no storage, so the same all-cold premium.
    function test_PushCost_OzERC20() public {
        (Cost[4] memory cs,) = _shape("OZ ERC20         ", oz, address(0), 1);
        assertEq(cs[2].used - cs[0].used, 2_500 + 4_800, "RIG: all cold must re-pay the token account and the hub's word");
    }

    /// @notice USDC shape: two accounts, the admin, implementation, pause and hub-blacklist words, and the hub's balance word.
    function test_PushCost_UsdcShapedProxy() public {
        (Cost[4] memory cs,) = _shape("USDC-shaped proxy", usdc, _implOf(usdc), 2);
        assertEq(cs[2].used - cs[0].used, 2 * 2_500 + 4 * 2_000 + 4_800, "RIG: all cold must re-pay every word the warm-up pull read");
    }

    /// @notice The repo's no-return mock: MockERC20's storage, plus the wrapper's code-size check on an empty return.
    function test_PushCost_MockNoReturnERC20() public {
        (Cost[4] memory cs,) = _shape("MockNoReturn     ", noRet, address(0), 1);
        assertEq(cs[2].used - cs[0].used, 2_500 + 4_800, "RIG: all cold must re-pay the token account and the hub's word");
    }

    /// @notice USDT shape: the pull re-warms the pause, deprecation and fee words; the hub's OWN blacklist word is cold in both.
    function test_PushCost_UsdtShaped() public {
        (Cost[4] memory cs,) = _shape("USDT-shaped      ", usdt, address(0), 1);
        assertEq(cs[2].used - cs[0].used, 2_500 + 4 * 2_000 + 4_800, "RIG: all cold must re-pay every word the warm-up pull read");
    }

    /// @notice The worst offline need, and the budgets at twice and three times it.
    function test_PushCost_WorstOfflineShape() public {
        uint256 worst;
        uint256 w;
        (, w) = _shape("MockERC20        ", plain, address(0), 1);
        if (w > worst) worst = w;
        (, w) = _shape("OZ ERC20         ", oz, address(0), 1);
        if (w > worst) worst = w;
        (, w) = _shape("USDC-shaped proxy", usdc, _implOf(usdc), 2);
        if (w > worst) worst = w;
        (, w) = _shape("MockNoReturn     ", noRet, address(0), 1);
        if (w > worst) worst = w;
        (, w) = _shape("USDT-shaped      ", usdt, address(0), 1);
        if (w > worst) worst = w;
        emit log_named_uint("PUSH-COST | WORST offline need", worst);
        emit log_named_uint("PUSH-COST | 2x worst", 2 * worst);
        emit log_named_uint("PUSH-COST | 3x worst", 3 * worst);
        assertLt(worst, HI, "the worst need sits under the ceiling budget");
    }

    /// @notice THE MAINNET BUDGET COVERS TWICE THE WORST PLAIN SHAPE, the vault's own quote included, and the fixture hub runs it.
    /// @dev The fixture's budget (`PocDeployConfig.PUSH_GAS`); `deploy/chains/mainnet.json` is kept equal by hand.
    /// @dev A vault's quote is its asset, so the USDC shape is the vault's push; its budget-to-need ratio is logged for the push-gas re-measure.
    function test_TheMainnetBudgetCoversTheWorstShapeAndTheVaultsQuote() public {
        uint256 worst;
        uint256 w;
        (, w) = _shape("MockERC20        ", plain, address(0), 1);
        if (w > worst) worst = w;
        (, w) = _shape("OZ ERC20         ", oz, address(0), 1);
        if (w > worst) worst = w;
        (, uint256 usdcNeed) = _shape("USDC-shaped proxy", usdc, _implOf(usdc), 2);
        if (usdcNeed > worst) worst = usdcNeed;
        (, w) = _shape("MockNoReturn     ", noRet, address(0), 1);
        if (w > worst) worst = w;
        (, w) = _shape("USDT-shaped      ", usdt, address(0), 1);
        if (w > worst) worst = w;
        emit log_named_uint("PUSH-COST | WORST offline need", worst);
        emit log_named_uint("PUSH-COST | the vault's quote (USDC shape) need", usdcNeed);
        emit log_named_uint("PUSH-COST | budget over the vault's quote need, x100", (AceFixtures.PUSH_GAS * 100) / usdcNeed);
        emit log_named_uint("PUSH-COST | the budget the hub runs", ace.PUSH_GAS());
        assertEq(ace.PUSH_GAS(), AceFixtures.PUSH_GAS, "premise: the fixture hub runs the fixture budget");
        assertGe(AceFixtures.PUSH_GAS, 2 * worst, "the mainnet budget no longer covers twice the worst plain shape");
        assertGe(AceFixtures.PUSH_GAS, 2 * usdcNeed, "the mainnet budget no longer covers twice the vault's own quote");
    }
}
