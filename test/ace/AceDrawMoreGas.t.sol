// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {DrawMoreRig} from "../utils/DrawMoreRig.sol";

/// @title AceDrawMoreGasTest
/// @notice The cost the top-up verbs exist to save, pinned against `open`: each measured with the hub, custody, tokens, record and title cooled.
/// @notice A top-up skips the title mint, the fresh loan slots, the market list push and the custody pull; an add skips everything but the pull.
/// @dev The linked libraries stay warm, as they do in any transaction that reached the hub before; the absolute ceilings carry that slack.
contract AceDrawMoreGasTest is DrawMoreRig {
    uint256 internal constant U = 1_000e18;

    function setUp() public override {
        super.setUp();
        _deposit(id, alice, 8 * P);
    }

    function _cool() internal {
        vm.cool(address(ace));
        vm.cool(address(pm));
        vm.cool(address(usdc));
        vm.cool(address(coll));
        vm.cool(address(rec));
        vm.cool(address(titles));
        vm.cool(address(yes));
    }

    function _gas() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    /// @dev `who` opens `P` for `LONG` at a fifth of the price, cooled; returns the loan and the call's gas.
    function _coldOpen(address who) internal returns (uint256 loanId, uint256 used) {
        uint256 units = _units(P, 2000);
        coll.mint(who, units);
        vm.startPrank(who);
        coll.approve(address(pm), units);
        usdc.approve(address(ace), type(uint256).max);
        vm.stopPrank();
        _cool();
        vm.prank(who);
        loanId = ace.open(id, units, P, LONG, who, _none());
        used = _gas();
    }

    /// @notice A cold top-up costs under half a cold open, an add under a third, and a stranger's extension within 20k of the holder's.
    function test_GasPins_DrawMoreAddCollateralAndAStrangersExtendAgainstOpen() public {
        (uint256 loanId, uint256 gOpen) = _coldOpen(borrower);
        (uint256 twin,) = _coldOpen(keeper);
        _warpBy(1 days);

        _cool();
        vm.prank(borrower);
        hub.drawMore(loanId, P / 4, _none());
        uint256 gDraw = _gas();

        coll.mint(stranger, U);
        vm.prank(stranger);
        coll.approve(address(pm), U);
        _cool();
        vm.prank(stranger);
        hub.addCollateral(loanId, U, "");
        uint256 gAdd = _gas();

        _warpTo(uint256(read.loan(loanId).expiry) - LONG / 4);
        _fund(stranger, _ceiling(loanId));
        _fund(keeper, _ceiling(twin));
        _cool();
        vm.prank(stranger);
        ace.extend(loanId, 0, "");
        uint256 gStranger = _gas();
        _cool();
        vm.prank(keeper);
        ace.extend(twin, 0, "");
        uint256 gHolder = _gas();

        emit log_named_uint("open, cold", gOpen);
        emit log_named_uint("drawMore, cold", gDraw);
        emit log_named_uint("addCollateral, cold", gAdd);
        emit log_named_uint("extend by a stranger, cold", gStranger);
        emit log_named_uint("extend by the holder, cold", gHolder);
        assertLt(gDraw * 2, gOpen, "a top-up must cost under half an open");
        assertLt(gAdd * 3, gOpen, "an add must cost under a third of an open");
        assertLt(gStranger, gHolder + 20_000, "a stranger's extension must cost within 20k of the holder's");
        assertLt(gDraw, 200_000, "the top-up's absolute ceiling");
        assertLt(gAdd, 120_000, "the add's absolute ceiling");
    }
}
