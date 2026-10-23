// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title MockHostileGasERC20
/// @notice A quote that attacks the CALLER'S GAS rather than refusing, which is the shape a fence has to survive.
/// @notice Three hostilities, each armable alone: burn to out-of-gas, burn down to a floor and succeed, return a bomb.
/// @dev `MockBlockableERC20` already covers the REVERTER, and a reverter is the easy case -- it returns cheaply and
/// @dev the caller keeps its whole retained allowance. None of the three below returns cheaply, and that is the point.
/// @dev BURN-TO-OOG is the fence's real adversary: the sub-call consumes every gas unit it is handed and dies, so
/// @dev whatever the caller retained is the whole of what its own tail may run on.
/// @dev THE RETURN BOMB is billed to the CALLER, not the callee, whenever the caller copies the whole returndata --
/// @dev which is why a one-word output window is what makes a reserve sizeable at all.
/// @dev A BOUNDED burn that then SUCCEEDS is the third shape and the sneakiest: nothing fails, and the caller's
/// @dev remaining work silently runs on fumes.
contract MockHostileGasERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    bool public burnAll; // spin on SSTORE until the call runs out of gas
    bool public reverting; // plain refusal, the cheap-to-return shape a fence does NOT have to survive
    address public burnOnlyTo; // when set, every burn shape arms only on a transfer TO this address; packed beside the flags
    uint64 public spinFloor; // when set, spin cheaply until gasleft() is under this, then report success WITHOUT moving
    uint256 public burnToFloor; // spin until gasleft() drops under this, then transfer normally
    uint256 public bombWords; // words of returndata `transfer` answers with; 32768 words is 1 MiB
    uint256 private _sink; // the slot the burn writes, so nothing can optimize the loop away

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n, string memory s, uint8 d) {
        (name, symbol, decimals) = (n, s, d);
    }

    /// @notice Arm the out-of-gas burn: every `transfer` from here consumes its whole allowance and dies.
    function setBurnAll(bool on) external {
        burnAll = on;
    }

    /// @notice Arm a plain refusal, so one fixture covers the reverter beside the three gas shapes.
    function setReverting(bool on) external {
        reverting = on;
    }

    /// @notice Arm a BOUNDED burn: `transfer` spins until `gasleft()` is under `floor`, then succeeds normally.
    function setBurnToFloor(uint256 floor) external {
        burnToFloor = floor;
    }

    /// @notice Arm the return bomb: `transfer` succeeds and answers with `words` words of returndata.
    /// @dev 32768 words is 1 MiB, which the design record measures at ~2,200,984 gas to copy.
    function setBombWords(uint256 words) external {
        bombWords = words;
    }

    /// @notice Aim every armed burn at ONE recipient, so a treasury-only burn leaves the lender's push honest.
    /// @dev Zero restores the default, where a burn fires on every `transfer`.
    function setBurnOnlyTo(address to) external {
        burnOnlyTo = to;
    }

    /// @notice Arm a SUCCESS THAT SPENDS ITS WHOLE BUDGET: `transfer` spins until `gasleft()` is under `floor`, then returns true.
    /// @dev The spin is a bare `gasleft` loop, a few gas a lap, so the budget left unspent is under `floor` to within a lap.
    /// @dev It moves NO balance: the caller's post-call path after a near-total spend is the whole subject, never the delivery.
    function setSpinFloor(uint64 floor) external {
        spinFloor = floor;
    }

    /// @notice Free mint for test wiring.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Standard ERC20 approval.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice ERC20 transfer, hostile in whichever dimension is armed.
    /// @dev The bomb is returned INSTEAD of the bool, so a caller copying the whole window pays for every word.
    function transfer(address to, uint256 amount) external returns (bool) {
        require(!reverting, "hostile quote refuses");
        address only = burnOnlyTo;
        bool armed = only == address(0) || only == to;
        uint256 spin = spinFloor;
        if (armed && spin != 0) {
            while (gasleft() > spin) {}
            return true;
        }
        if (armed) _burn();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        if (armed) _bomb();
        return true;
    }

    /// @notice ERC20 transferFrom, left HONEST so a test can fund through it while `transfer` is armed.
    /// @dev The fence protects a PUSH, and every push in the hub is a `transfer`; arming the pull side too
    /// @dev would only stop the fixture funding itself and would prove nothing about the seam under test.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @dev SSTORE to a fresh slot each turn, ~22,100 gas a lap, so the spin cannot be folded away or cached.
    function _burn() private {
        if (burnAll) {
            uint256 i = _sink;
            while (true) {
                assembly {
                    sstore(i, add(i, 1))
                }
                unchecked {
                    ++i;
                }
            }
        }
        if (burnToFloor != 0) {
            uint256 i = _sink + 1e6; // a different slot range, so the two shapes cannot collide
            while (gasleft() > burnToFloor) {
                assembly {
                    sstore(i, add(i, 1))
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @dev Answers with `bombWords` words of zeros, which costs the CALLER memory expansion if it copies them.
    function _bomb() private view {
        uint256 words = bombWords;
        if (words == 0) return;
        assembly ("memory-safe") {
            let size := mul(words, 32)
            let p := mload(0x40)
            return(p, size)
        }
    }
}
